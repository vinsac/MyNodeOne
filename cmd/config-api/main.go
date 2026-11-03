// MyNodeOne Config API Server
//
// A lightweight HTTP server that serves configuration to nodes in the cluster.
// Nodes poll this server for config updates and send heartbeats.
//
// Endpoints:
//   GET    /api/v1/config/{node-type}          - Config for node type (laptop, vps, worker)
//   GET    /api/v1/config/vps/traefik-config   - Rendered Traefik routes
//   POST   /api/v1/heartbeat                   - Node reports its status
//   GET    /api/v1/nodes                       - List all nodes and their status
//   DELETE /api/v1/nodes/{name}                - Remove a node (local admin, or the node itself)
//   GET    /api/v1/health                      - Health check
//
// Authentication:
//   - Source address must be on the tailnet or loopback
//   - API token in the X-API-Token header. The server refuses to start without one.
//
// Transport is plain HTTP. Confidentiality comes from Tailscale's WireGuard
// tunnel, so the server binds to loopback and the Tailscale IP by default.
//
// Failure semantics: a config response with HTTP 200 is authoritative. An empty
// "routes" or "dns_entries" array means the registry was read and holds nothing.
// If the registry cannot be read the server answers 503, so an agent never
// mistakes a control plane problem for "remove everything".

package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"gopkg.in/yaml.v3"
)

// registrySchemaVersion is advertised on /api/v1/health. Version 2 means this
// binary understands namespace/name registry keys. service-registry.sh waits for
// it before migrating a bare-keyed registry.
const registrySchemaVersion = 2

const (
	kubectlTimeout     = 10 * time.Second
	maxHeartbeatBytes  = 64 * 1024
	bindModeTailscale  = "tailscale"
	tailscaleRetryWait = 5 * time.Second
)

// errRegistryUnavailable marks "the registry could not be read". Handlers map it
// to 503. It must never be turned into an empty result.
var errRegistryUnavailable = errors.New("registry unavailable")

// errUnknownNodeType marks a config request for a node type we do not serve.
var errUnknownNodeType = errors.New("unknown node type")

// kubectlRunner runs kubectl and returns stdout. Injected so tests can fake it.
type kubectlRunner func(ctx context.Context, args ...string) ([]byte, error)

func execKubectl(ctx context.Context, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, "kubectl", args...).Output()
}

var (
	// Metrics
	nodeCount = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "mynodeone_nodes_count",
			Help: "Number of registered nodes by type and status",
		},
		[]string{"type", "status"},
	)
	configRequests = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "mynodeone_config_requests_total",
			Help: "Total number of config requests",
		},
		[]string{"node_type", "status"},
	)
)

func init() {
	// Register metrics
	prometheus.MustRegister(nodeCount)
	prometheus.MustRegister(configRequests)
}

// Configuration
type Config struct {
	Port                   int
	BindIP                 string
	APIToken               string
	HeartbeatOnlineSeconds int
	HeartbeatStaleSeconds  int
	RequireTailscaleIP     bool
}

// Node represents a registered node
type Node struct {
	Name          string    `json:"name"`
	Type          string    `json:"type"`
	IP            string    `json:"ip"`
	Status        string    `json:"status"`
	LastHeartbeat time.Time `json:"last_heartbeat"`
	ConfigVersion string    `json:"config_version"`
	UptimeSeconds int64     `json:"uptime_seconds,omitempty"`
}

// HeartbeatRequest is the payload from node agents
type HeartbeatRequest struct {
	NodeName      string `json:"node_name"`
	NodeType      string `json:"node_type"`
	NodeIP        string `json:"node_ip"`
	ConfigVersion string `json:"config_version"`
	UptimeSeconds int64  `json:"uptime_seconds"`
}

// DNSEntry represents a DNS entry for /etc/hosts
type DNSEntry struct {
	Name string `json:"name"`
	IP   string `json:"ip"`
}

// TraefikRoute represents a route for VPS Traefik
// Clean Separation: Uses full domains from routing registry
type TraefikRoute struct {
	Service      string   `json:"service"`                 // Stable route ID (e.g., "open-webui"), safe for Traefik names
	Domain       string   `json:"domain"`                  // Full domain (e.g., "curiios.com", "chat.curiios.com")
	Backend      string   `json:"backend"`                 // Backend address (e.g., "100.72.41.208:80")
	BlockedPaths []string `json:"blocked_paths,omitempty"` // Path prefixes not served on the public route
}

// Traefik Configuration Structs (for YAML generation)
type TraefikConfig struct {
	HTTP HTTPConfig `yaml:"http"`
}

type HTTPConfig struct {
	Routers     map[string]Router     `yaml:"routers,omitempty"`
	Services    map[string]Service    `yaml:"services,omitempty"`
	Middlewares map[string]Middleware `yaml:"middlewares,omitempty"`
}

type Router struct {
	Rule        string   `yaml:"rule"`
	Service     string   `yaml:"service"`
	EntryPoints []string `yaml:"entryPoints,omitempty"`
	TLS         *TLS     `yaml:"tls,omitempty"`
	Middlewares []string `yaml:"middlewares,omitempty"`
}

type TLS struct {
	CertResolver string `yaml:"certResolver,omitempty"`
}

type Service struct {
	LoadBalancer LoadBalancer `yaml:"loadBalancer"`
}

type LoadBalancer struct {
	Servers []ServerURL `yaml:"servers"`
}

type ServerURL struct {
	URL string `yaml:"url"`
}

type Middleware struct {
	RedirectScheme *RedirectScheme `yaml:"redirectScheme,omitempty"`
}

type RedirectScheme struct {
	Scheme    string `yaml:"scheme"`
	Permanent bool   `yaml:"permanent"`
}

// ConfigResponse is the response for /api/v1/config/{type}
//
// The fields are pointers so that "not applicable to this node type" (absent)
// stays distinct from "confirmed empty" (an explicit []). Never point them at a
// nil slice: that would encode as null.
type ConfigResponse struct {
	Version    string          `json:"version"`
	Timestamp  time.Time       `json:"timestamp"`
	DNSEntries *[]DNSEntry     `json:"dns_entries,omitempty"`
	Routes     *[]TraefikRoute `json:"routes,omitempty"`
}

// NodesResponse is the response for /api/v1/nodes
type NodesResponse struct {
	Nodes []Node `json:"nodes"`
}

// Server holds the API server state
type Server struct {
	config    Config
	nodes     map[string]*Node
	nodesMu   sync.RWMutex
	configVer string
	verMu     sync.RWMutex
	nodesFile string
	saveMu    sync.Mutex
	kubectl   kubectlRunner

	// Last seen resourceVersions, used by checkConfigChanges
	lastServiceRV string
	lastDomainRV  string
}

const defaultNodesFile = "/etc/mynodeone/nodes-registry.json"

func NewServer(cfg Config) *Server {
	s := &Server{
		config:    cfg,
		nodes:     make(map[string]*Node),
		configVer: fmt.Sprintf("v%d", time.Now().Unix()),
		nodesFile: defaultNodesFile,
		kubectl:   execKubectl,
	}
	// Load persisted nodes
	s.loadNodes()
	return s
}

func (s *Server) version() string {
	s.verMu.RLock()
	defer s.verMu.RUnlock()
	return s.configVer
}

func (s *Server) setVersion(v string) {
	s.verMu.Lock()
	defer s.verMu.Unlock()
	s.configVer = v
}

// Tailscale assigns IPv4 addresses from the CGNAT range and IPv6 addresses from
// its own ULA prefix. A bare "100." prefix check would also admit public 100.x
// addresses.
var (
	tailscaleV4Net = mustCIDR("100.64.0.0/10")
	tailscaleV6Net = mustCIDR("fd7a:115c:a1e0::/48")
)

func mustCIDR(s string) *net.IPNet {
	_, n, err := net.ParseCIDR(s)
	if err != nil {
		panic(err)
	}
	return n
}

// isTailnetOrLoopback reports whether an address may talk to the API at all.
func isTailnetOrLoopback(ip net.IP) bool {
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || tailscaleV4Net.Contains(ip) || tailscaleV6Net.Contains(ip)
}

func remoteIP(r *http.Request) net.IP {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	return net.ParseIP(host)
}

// isLocalRequest reports whether the request came from this host: loopback, or
// the source address equals the address the connection arrived on (the control
// plane calling its own Tailscale IP).
func isLocalRequest(r *http.Request) bool {
	ip := remoteIP(r)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	if addr, ok := r.Context().Value(http.LocalAddrContextKey).(net.Addr); ok && addr != nil {
		host, _, err := net.SplitHostPort(addr.String())
		if err == nil {
			if local := net.ParseIP(host); local != nil && local.Equal(ip) {
				return true
			}
		}
	}
	return false
}

// tokenMatches compares in constant time. Both sides are hashed first because
// subtle.ConstantTimeCompare returns early on a length mismatch. An empty
// configured token never matches.
func tokenMatches(configured, presented string) bool {
	if configured == "" {
		return false
	}
	a := sha256.Sum256([]byte(configured))
	b := sha256.Sum256([]byte(presented))
	return subtle.ConstantTimeCompare(a[:], b[:]) == 1
}

// Middleware: Verify source address and API token
func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := remoteIP(r)
		clientIP := r.RemoteAddr
		if ip != nil {
			clientIP = ip.String()
		}

		if s.config.RequireTailscaleIP && !isTailnetOrLoopback(ip) {
			log.Printf("DENIED: Non-Tailscale IP %s tried to access %s", clientIP, r.URL.Path)
			http.Error(w, "Forbidden: Must connect via Tailscale", http.StatusForbidden)
			return
		}

		if !tokenMatches(s.config.APIToken, r.Header.Get("X-API-Token")) {
			log.Printf("DENIED: Invalid API token from %s", clientIP)
			http.Error(w, "Unauthorized: Invalid API token", http.StatusUnauthorized)
			return
		}

		next(w, r)
	}
}

// Middleware: Metrics
func (s *Server) metricsMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		next(rw, r)
		duration := time.Since(start)

		// Basic request logging
		clientIP, _, _ := net.SplitHostPort(r.RemoteAddr)
		log.Printf("%s %s %s (%d) %v", r.Method, r.URL.Path, clientIP, rw.status, duration)
	}
}

type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}

// GET /api/v1/health
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":          "ok",
		"server_time":     time.Now().UTC(),
		"version":         "1.0.0",
		"registry_schema": registrySchemaVersion,
	})
}

// writeRegistryUnavailable answers 503. The body is deliberately not JSON so a
// tolerant client cannot parse it as a config.
func writeRegistryUnavailable(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "30")
	http.Error(w, "Service unavailable: registry could not be read", http.StatusServiceUnavailable)
}

// GET /api/v1/config/{type}
func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) {
	// Extract node type from path
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/config/")
	nodeType := strings.TrimSuffix(path, "/")

	if nodeType == "" {
		http.Error(w, "Node type required", http.StatusBadRequest)
		return
	}
	switch nodeType {
	case "laptop", "worker", "vps":
	default:
		// Checked before the metrics label so a client cannot create unbounded series.
		http.Error(w, "Unknown node type", http.StatusNotFound)
		return
	}

	// Get node name from header (for logging)
	nodeName := r.Header.Get("X-Node-Name")
	clientIP, _, _ := net.SplitHostPort(r.RemoteAddr)
	log.Printf("Config request: type=%s node=%q ip=%s", nodeType, nodeName, clientIP)

	// Fetch config from Kubernetes ConfigMaps
	response, err := s.getConfigForNodeType(r.Context(), nodeType)
	if err != nil {
		log.Printf("Error getting config: %v", err)
		configRequests.WithLabelValues(nodeType, "unavailable").Inc()
		if errors.Is(err, errRegistryUnavailable) {
			writeRegistryUnavailable(w)
			return
		}
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Update request metrics
	configRequests.WithLabelValues(nodeType, "success").Inc()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// GET /api/v1/config/vps/traefik-config
func (s *Server) handleTraefikConfig(w http.ResponseWriter, r *http.Request) {
	// First get the routes
	routes, err := s.getTraefikRoutes(r.Context())
	if err != nil {
		log.Printf("Error getting routes: %v", err)
		if errors.Is(err, errRegistryUnavailable) {
			writeRegistryUnavailable(w)
			return
		}
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Generate Traefik YAML configuration
	config := s.generateTraefikConfig(routes)

	// Marshal to YAML
	data, err := yaml.Marshal(config)
	if err != nil {
		log.Printf("Error marshaling YAML: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Add header comment
	header := fmt.Sprintf("# MyNodeOne Routes (Generated via Config API)\n# Generated: %s\n\n", time.Now().Format(time.RFC3339))

	w.Header().Set("Content-Type", "application/x-yaml")
	w.Write([]byte(header))
	w.Write(data)
}

// traefikRule builds the router rule for a public route. Blocked prefixes are
// excluded so those paths match no router and Traefik answers 404. Tailnet
// clients reach the LoadBalancer IP directly and keep full access.
func traefikRule(domain string, blockedPaths []string) string {
	rule := fmt.Sprintf("Host(`%s`)", domain)
	for _, p := range blockedPaths {
		rule += fmt.Sprintf(" && !PathPrefix(`%s`)", p)
	}
	return rule
}

// routerNames gives each route its HTTPS router name, service-domain with the dots in
// the domain as dashes, e.g. immich-immich-example-com. Its HTTP router adds -http.
// That mapping can give two routes one name: chat-api on example.com and chat on
// api.example.com. Those routes get a hash of their service and domain added, and only
// those, because a renamed router makes Traefik drop and rebuild it.
func routerNames(routes []TraefikRoute) []string {
	names := make([]string, len(routes))
	uses := make(map[string]int, 2*len(routes))
	for i, route := range routes {
		names[i] = fmt.Sprintf("%s-%s", route.Service, strings.ReplaceAll(route.Domain, ".", "-"))
		uses[names[i]]++
		uses[names[i]+"-http"]++
	}
	unique := make([]string, len(routes))
	for i, route := range routes {
		unique[i] = names[i]
		if uses[names[i]] > 1 || uses[names[i]+"-http"] > 1 {
			sum := sha256.Sum256([]byte(route.Service + "|" + route.Domain))
			unique[i] = fmt.Sprintf("%s-%x", names[i], sum[:4])
		}
	}
	return unique
}

func (s *Server) generateTraefikConfig(routes []TraefikRoute) TraefikConfig {
	config := TraefikConfig{
		HTTP: HTTPConfig{
			Routers:     make(map[string]Router),
			Services:    make(map[string]Service),
			Middlewares: make(map[string]Middleware),
		},
	}

	// Add https-redirect middleware
	config.HTTP.Middlewares["https-redirect"] = Middleware{
		RedirectScheme: &RedirectScheme{
			Scheme:    "https",
			Permanent: true,
		},
	}

	names := routerNames(routes)
	for i, route := range routes {
		rule := traefikRule(route.Domain, route.BlockedPaths)

		// HTTPS Router
		routerName := names[i]
		config.HTTP.Routers[routerName] = Router{
			Rule:        rule,
			Service:     route.Service + "-service", // Suffix with -service to match V1
			EntryPoints: []string{"websecure"},
			TLS:         &TLS{CertResolver: "letsencrypt"},
		}

		// HTTP Router (Redirect)
		config.HTTP.Routers[routerName+"-http"] = Router{
			Rule:        rule,
			Service:     route.Service + "-service",
			EntryPoints: []string{"web"},
			Middlewares: []string{"https-redirect"},
		}

		// One backend per registry entry. Route IDs are unique per entry (see
		// assignRouteIDs), so this never merges two different services.
		serviceName := route.Service + "-service"
		config.HTTP.Services[serviceName] = Service{
			LoadBalancer: LoadBalancer{
				Servers: []ServerURL{
					{URL: "http://" + route.Backend},
				},
			},
		}
	}

	return config
}

// nodeNameRe bounds node names: they are map keys, log fields and URL path parts.
var nodeNameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$`)

// POST /api/v1/heartbeat
func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxHeartbeatBytes)
	var req HeartbeatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			http.Error(w, "Request body too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	if req.NodeName == "" || req.NodeType == "" {
		http.Error(w, "node_name and node_type required", http.StatusBadRequest)
		return
	}
	if !nodeNameRe.MatchString(req.NodeName) || !nodeNameRe.MatchString(req.NodeType) {
		http.Error(w, "Invalid node_name or node_type", http.StatusBadRequest)
		return
	}

	// The token is shared by every node, so a claimed IP proves nothing. Record
	// the address the request came from. Loopback is the only case where the
	// observed address is less useful than the claim.
	observed := remoteIP(r)
	nodeIP := ""
	if observed != nil {
		nodeIP = observed.String()
	}
	if observed == nil || observed.IsLoopback() {
		if claimed := net.ParseIP(req.NodeIP); claimed != nil {
			nodeIP = claimed.String()
		}
	}

	now := time.Now()

	// Update node registry
	s.nodesMu.Lock()
	existing := s.nodes[req.NodeName]
	if existing != nil && existing.IP != nodeIP && net.ParseIP(existing.IP) != nil && net.ParseIP(nodeIP) != nil &&
		now.Sub(existing.LastHeartbeat) <= time.Duration(s.config.HeartbeatOnlineSeconds)*time.Second {
		// A live node owns its name. A node that really changed address is
		// accepted once its old record stops being online.
		s.nodesMu.Unlock()
		log.Printf("DENIED: heartbeat for %s from %s, name is held by online node at %s", req.NodeName, nodeIP, existing.IP)
		http.Error(w, "Conflict: node name is in use by another online node", http.StatusConflict)
		return
	}
	isNewNode := existing == nil
	s.nodes[req.NodeName] = &Node{
		Name:          req.NodeName,
		Type:          req.NodeType,
		IP:            nodeIP,
		Status:        "online",
		LastHeartbeat: now,
		ConfigVersion: req.ConfigVersion,
		UptimeSeconds: req.UptimeSeconds,
	}
	s.nodesMu.Unlock()

	// Persist immediately for new nodes
	if isNewNode {
		s.saveNodes()
		log.Printf("New node registered: %s (%s) at %s", req.NodeName, req.NodeType, nodeIP)
	} else {
		log.Printf("Heartbeat: node=%s type=%s ip=%s config=%s",
			req.NodeName, req.NodeType, nodeIP, req.ConfigVersion)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":      "ok",
		"server_time": time.Now().UTC(),
	})
}

// DELETE /api/v1/nodes/{name} - Remove a node from registry
//
// Allowed from the control plane itself, or from the node being removed (the
// uninstaller deregisters itself). Any other token holder gets 403, so one
// compromised node cannot erase the others.
func (s *Server) handleNodeDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Extract node name from path
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/nodes/")
	nodeName := strings.TrimSuffix(path, "/")

	if nodeName == "" {
		http.Error(w, "Node name required", http.StatusBadRequest)
		return
	}

	local := isLocalRequest(r)
	source := remoteIP(r)

	s.nodesMu.Lock()
	node, exists := s.nodes[nodeName]
	if !exists {
		s.nodesMu.Unlock()
		http.Error(w, "Node not found", http.StatusNotFound)
		return
	}
	nodeAddr := net.ParseIP(node.IP)
	isSelf := source != nil && nodeAddr != nil && nodeAddr.Equal(source)
	if !local && !isSelf {
		s.nodesMu.Unlock()
		log.Printf("DENIED: %s tried to delete node %s", source, nodeName)
		http.Error(w, "Forbidden: nodes can only be removed from the control plane", http.StatusForbidden)
		return
	}
	delete(s.nodes, nodeName)
	s.nodesMu.Unlock()

	s.saveNodes() // Persist change
	log.Printf("Node removed: %s", nodeName)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "removed", "node": nodeName})
}

// GET /api/v1/nodes
func (s *Server) handleNodes(w http.ResponseWriter, r *http.Request) {
	s.nodesMu.RLock()
	defer s.nodesMu.RUnlock()

	nodes := make([]Node, 0, len(s.nodes))
	now := time.Now()

	for _, node := range s.nodes {
		// Calculate status based on last heartbeat
		elapsed := now.Sub(node.LastHeartbeat)
		status := "online"
		if elapsed > time.Duration(s.config.HeartbeatStaleSeconds)*time.Second {
			status = "offline"
		} else if elapsed > time.Duration(s.config.HeartbeatOnlineSeconds)*time.Second {
			status = "stale"
		}

		nodes = append(nodes, Node{
			Name:          node.Name,
			Type:          node.Type,
			IP:            node.IP,
			Status:        status,
			LastHeartbeat: node.LastHeartbeat,
			ConfigVersion: node.ConfigVersion,
			UptimeSeconds: node.UptimeSeconds,
		})
	}

	// Update metrics
	s.updateMetrics()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(NodesResponse{Nodes: nodes})
}

func (s *Server) updateMetrics() {
	// Reset metrics
	nodeCount.Reset()

	now := time.Now()
	for _, node := range s.nodes {
		elapsed := now.Sub(node.LastHeartbeat)
		status := "online"
		if elapsed > time.Duration(s.config.HeartbeatStaleSeconds)*time.Second {
			status = "offline"
		} else if elapsed > time.Duration(s.config.HeartbeatOnlineSeconds)*time.Second {
			status = "stale"
		}

		nodeCount.WithLabelValues(node.Type, status).Inc()
	}
}

// getConfigForNodeType fetches config from Kubernetes ConfigMaps
func (s *Server) getConfigForNodeType(ctx context.Context, nodeType string) (*ConfigResponse, error) {
	response := &ConfigResponse{
		Version:   s.version(),
		Timestamp: time.Now().UTC(),
	}

	switch nodeType {
	case "laptop", "worker":
		// Fetch DNS entries from service-registry ConfigMap
		entries, err := s.getDNSEntries(ctx)
		if err != nil {
			return nil, err
		}
		response.DNSEntries = &entries

	case "vps":
		// Fetch routes from service-registry ConfigMap
		routes, err := s.getTraefikRoutes(ctx)
		if err != nil {
			return nil, err
		}
		response.Routes = &routes

	default:
		return nil, fmt.Errorf("%w: %s", errUnknownNodeType, nodeType)
	}

	return response, nil
}

// readConfigMapJSON reads one data key of a kube-system ConfigMap and parses it
// as a JSON object. Every failure is errRegistryUnavailable: a kubectl error
// (including NotFound and timeouts), a blank value (kubectl exits 0 when the key
// is missing), invalid JSON, or valid JSON that is not an object. Only a parsed
// object, possibly {}, counts as "read".
func (s *Server) readConfigMapJSON(ctx context.Context, configMap, key string) (map[string]interface{}, error) {
	ctx, cancel := context.WithTimeout(ctx, kubectlTimeout)
	defer cancel()

	jsonPath := fmt.Sprintf("jsonpath={.data.%s}", strings.ReplaceAll(key, ".", "\\."))
	output, err := s.kubectl(ctx, "get", "configmap", "-n", "kube-system", configMap, "-o", jsonPath)
	if err != nil {
		return nil, fmt.Errorf("%w: reading %s: %v", errRegistryUnavailable, configMap, err)
	}
	if len(strings.TrimSpace(string(output))) == 0 {
		return nil, fmt.Errorf("%w: %s has no %s", errRegistryUnavailable, configMap, key)
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(output, &parsed); err != nil {
		return nil, fmt.Errorf("%w: parsing %s/%s: %v", errRegistryUnavailable, configMap, key, err)
	}
	if parsed == nil {
		return nil, fmt.Errorf("%w: %s/%s is null", errRegistryUnavailable, configMap, key)
	}
	return parsed, nil
}

// registryEntry is one parsed service-registry value. Parsing is by assertion, as
// it always was here, so one malformed field cannot take the whole registry down.
type registryEntry struct {
	Key         string
	Name        string // key without its namespace part
	LegacyKey   string // bare key from before the namespace/name migration
	LocalName   string
	Namespace   string
	ServiceName string
	IP          string
	Port        float64
	Public      bool

	blockedRaw interface{}
	blockedSet bool
}

func parseRegistry(services map[string]interface{}) []registryEntry {
	entries := make([]registryEntry, 0, len(services))
	for key, raw := range services {
		m, ok := raw.(map[string]interface{})
		if !ok {
			log.Printf("Registry entry %q is not an object, skipping", key)
			continue
		}
		e := registryEntry{Key: key, Name: key}
		if i := strings.LastIndex(key, "/"); i >= 0 {
			e.Name = key[i+1:]
		}
		e.LegacyKey, _ = m["legacy_key"].(string)
		e.LocalName, _ = m["local_name"].(string)
		e.Namespace, _ = m["namespace"].(string)
		e.ServiceName, _ = m["service"].(string)
		e.IP, _ = m["ip"].(string)
		e.Port, _ = m["port"].(float64)
		e.Public, _ = m["public"].(bool)
		e.blockedRaw, e.blockedSet = m["public_blocked_paths"]
		entries = append(entries, e)
	}
	// Map order is random. Sort so that collisions resolve the same way on every read.
	sort.Slice(entries, func(i, j int) bool { return entries[i].Key < entries[j].Key })
	return entries
}

var (
	// A single DNS label: this ends up as a hostname in /etc/hosts on every node.
	localNameRe = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$`)
	// A public hostname: at least two labels, and it goes inside a Traefik rule.
	publicDomainRe = regexp.MustCompile(`^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$`)
	// A path prefix: no backticks, parentheses, spaces or anything else a rule could trip on.
	blockedPathRe = regexp.MustCompile(`^/[A-Za-z0-9._~/-]+$`)
	nonRouteIDRe  = regexp.MustCompile(`[^A-Za-z0-9_-]+`)
)

// reservedLocalNames could capture local traffic if published as a hosts alias.
var reservedLocalNames = map[string]bool{
	"localhost": true, "localhost4": true, "localhost6": true, "broadcasthost": true,
	"ip6-localhost": true, "ip6-loopback": true, "ip6-allnodes": true, "ip6-allrouters": true,
	"ip6-localnet": true, "ip6-mcastprefix": true,
}

func validLocalName(name string) bool {
	return localNameRe.MatchString(name) && !reservedLocalNames[strings.ToLower(name)]
}

// getDNSEntries fetches DNS entries from service-registry ConfigMap
func (s *Server) getDNSEntries(ctx context.Context) ([]DNSEntry, error) {
	services, err := s.readConfigMapJSON(ctx, "service-registry", "services.json")
	if err != nil {
		return nil, err
	}
	return buildDNSEntries(parseRegistry(services)), nil
}

func buildDNSEntries(registry []registryEntry) []DNSEntry {
	entries := []DNSEntry{}
	seen := make(map[string]string) // name -> registry key

	for _, svc := range registry {
		if svc.IP == "" {
			continue
		}
		if svc.LocalName == "" {
			log.Printf("Service %s missing local_name, skipping DNS entry", svc.Key)
			continue
		}
		if !validLocalName(svc.LocalName) {
			log.Printf("Service %s has invalid local_name %q, skipping DNS entry", svc.Key, svc.LocalName)
			continue
		}
		if net.ParseIP(svc.IP) == nil {
			log.Printf("Service %s has invalid IP %q, skipping DNS entry", svc.Key, svc.IP)
			continue
		}
		if holder, taken := seen[svc.LocalName]; taken {
			log.Printf("WARNING: local name %s already used by %s, skipping for %s", svc.LocalName, holder, svc.Key)
			continue
		}
		seen[svc.LocalName] = svc.Key

		entries = append(entries, DNSEntry{Name: svc.LocalName, IP: svc.IP})
		// Dashboard also gets a bare domain entry (e.g., mynodeone.local)
		if svc.LocalName == "dashboard" {
			entries = append(entries, DNSEntry{Name: "", IP: svc.IP})
		}
	}
	return entries
}

// resolveBlockedPaths returns the prefixes to exclude from a public route. Nothing is
// blocked unless the entry sets public_blocked_paths. A malformed field is an error:
// the caller drops the route rather than publish it without the block.
func resolveBlockedPaths(e registryEntry) ([]string, error) {
	if !e.blockedSet {
		return nil, nil
	}
	list, ok := e.blockedRaw.([]interface{})
	if !ok {
		return nil, fmt.Errorf("public_blocked_paths is not an array")
	}
	paths := make([]string, 0, len(list))
	for _, raw := range list {
		p, ok := raw.(string)
		if !ok || !blockedPathRe.MatchString(p) {
			return nil, fmt.Errorf("invalid blocked path %v", raw)
		}
		paths = append(paths, p)
	}
	return paths, nil
}

func routeIDBase(e registryEntry) string {
	if e.LegacyKey != "" {
		return e.LegacyKey
	}
	return e.Name
}

// assignRouteIDs gives each public entry the ID its Traefik router and service
// names are built from. A migrated entry keeps its old name, so the live routers
// do not change. Two entries wanting one ID both fall back to namespace-name.
// IDs never contain a slash.
func assignRouteIDs(public []registryEntry) map[string]string {
	wanted := make(map[string]int)
	for _, e := range public {
		wanted[nonRouteIDRe.ReplaceAllString(routeIDBase(e), "-")]++
	}

	ids := make(map[string]string, len(public))
	used := make(map[string]bool, len(public))
	for _, e := range public {
		id := nonRouteIDRe.ReplaceAllString(routeIDBase(e), "-")
		if wanted[id] > 1 {
			id = nonRouteIDRe.ReplaceAllString(e.Namespace+"-"+e.Name, "-")
		}
		base := id
		for n := 2; used[id]; n++ {
			id = fmt.Sprintf("%s-%d", base, n)
		}
		used[id] = true
		ids[e.Key] = id
	}
	return ids
}

// resolveRouting maps each public entry to its routing record. Lookup is by exact
// registry key first. routing.json may still be keyed on a bare name from before
// the migration, so a bare key can also be claimed, but only when exactly one
// public entry without its own record wants it. Otherwise a same-named service in
// another namespace could inherit the public route, so the claim is refused.
func resolveRouting(public []registryEntry, routing map[string]interface{}) map[string]interface{} {
	resolved := make(map[string]interface{}, len(public))
	claimants := make(map[string][]string)

	directlyHeld := make(map[string]bool, len(public))
	for _, e := range public {
		if _, ok := routing[e.Key]; ok {
			directlyHeld[e.Key] = true
		}
	}

	for _, e := range public {
		if rec, ok := routing[e.Key]; ok {
			resolved[e.Key] = rec
			continue
		}
		seen := make(map[string]bool)
		for _, bare := range []string{e.LegacyKey, e.Name, e.ServiceName} {
			if bare == "" || seen[bare] || directlyHeld[bare] {
				continue
			}
			seen[bare] = true
			if _, ok := routing[bare]; ok {
				claimants[bare] = append(claimants[bare], e.Key)
			}
		}
	}

	bareKeys := make([]string, 0, len(claimants))
	for bare := range claimants {
		bareKeys = append(bareKeys, bare)
	}
	sort.Strings(bareKeys)
	for _, bare := range bareKeys {
		keys := claimants[bare]
		if len(keys) > 1 {
			log.Printf("WARNING: routing entry %q matches %d services (%s), route not published. Re-run manage-app-visibility.sh with namespace/name",
				bare, len(keys), strings.Join(keys, ", "))
			continue
		}
		if _, taken := resolved[keys[0]]; !taken {
			resolved[keys[0]] = routing[bare]
		}
	}
	return resolved
}

// backendAddress validates the registry's IP and port and joins them.
func backendAddress(e registryEntry) (string, error) {
	ip := net.ParseIP(e.IP)
	if ip == nil {
		return "", fmt.Errorf("invalid IP %q", e.IP)
	}
	if e.Port == 0 {
		if ip.To4() == nil {
			return "[" + ip.String() + "]", nil
		}
		return ip.String(), nil
	}
	if e.Port < 1 || e.Port > 65535 || e.Port != float64(int(e.Port)) {
		return "", fmt.Errorf("invalid port %v", e.Port)
	}
	return net.JoinHostPort(ip.String(), fmt.Sprintf("%d", int(e.Port))), nil
}

// getTraefikRoutes fetches routes for VPS from service-registry and domain-registry ConfigMaps
// Clean Separation: Uses expose array with full domains from routing registry
func (s *Server) getTraefikRoutes(ctx context.Context) ([]TraefikRoute, error) {
	// Step 1: Get service registry (for backend IPs and ports)
	services, err := s.readConfigMapJSON(ctx, "service-registry", "services.json")
	if err != nil {
		return nil, err
	}

	public := []registryEntry{}
	for _, e := range parseRegistry(services) {
		if e.Public {
			public = append(public, e)
		}
	}

	// No public service means no routes, whatever domain-registry holds. A cluster
	// that never set up domains has no domain-registry, and that is not an error.
	if len(public) == 0 {
		log.Printf("Generated 0 routes for VPS nodes")
		return []TraefikRoute{}, nil
	}

	// Step 2: Get routing config. Public services exist, so failing to read it
	// must not look like "these services have no routes".
	// Format: {"servicename": {"expose": ["curiios.com", "www.curiios.com"], ...}, ...}
	routing, err := s.readConfigMapJSON(ctx, "domain-registry", "routing.json")
	if err != nil {
		return nil, err
	}

	return buildRoutes(public, routing), nil
}

// buildRoutes turns public registry entries and routing records into routes.
func buildRoutes(public []registryEntry, routing map[string]interface{}) []TraefikRoute {
	routes := []TraefikRoute{}
	seenDomains := make(map[string]string) // For duplicate detection
	ids := assignRouteIDs(public)
	records := resolveRouting(public, routing)

	for _, e := range public {
		if e.IP == "" {
			log.Printf("Service %s has no IP, skipping", e.Key)
			continue
		}
		backend, err := backendAddress(e)
		if err != nil {
			log.Printf("Service %s: %v, skipping", e.Key, err)
			continue
		}

		// Check if service has routing config
		record, exists := records[e.Key]
		if !exists {
			log.Printf("Service %s is public but has no routing config", e.Key)
			continue
		}
		routingMap, ok := record.(map[string]interface{})
		if !ok {
			log.Printf("Service %s routing config is invalid", e.Key)
			continue
		}

		// Get expose array (list of full domains)
		exposeRaw, ok := routingMap["expose"].([]interface{})
		if !ok {
			log.Printf("Service %s routing config missing 'expose' array", e.Key)
			continue
		}

		blocked, err := resolveBlockedPaths(e)
		if err != nil {
			log.Printf("Service %s: %v, not publishing its routes", e.Key, err)
			continue
		}

		// Create route for each exposed domain
		for _, domainRaw := range exposeRaw {
			fullDomain, ok := domainRaw.(string)
			if !ok || fullDomain == "" {
				continue
			}
			if !publicDomainRe.MatchString(fullDomain) {
				log.Printf("Service %s: invalid domain %q, skipping", e.Key, fullDomain)
				continue
			}

			// Check for duplicate domains across services
			if existingService, exists := seenDomains[fullDomain]; exists {
				log.Printf("WARNING: Domain %s already used by %s, skipping for %s",
					fullDomain, existingService, e.Key)
				continue
			}
			seenDomains[fullDomain] = e.Key

			log.Printf("  Route: https://%s -> %s", fullDomain, backend)
			routes = append(routes, TraefikRoute{
				Service:      ids[e.Key],
				Domain:       fullDomain,
				Backend:      backend,
				BlockedPaths: blocked,
			})
		}
	}

	log.Printf("Generated %d routes for VPS nodes", len(routes))
	return routes
}

// loadNodes loads the node registry from disk
func (s *Server) loadNodes() {
	data, err := os.ReadFile(s.nodesFile)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("Warning: Failed to load nodes registry: %v", err)
		}
		return
	}

	var nodes map[string]*Node
	if err := json.Unmarshal(data, &nodes); err != nil {
		log.Printf("Warning: Failed to parse nodes registry: %v", err)
		return
	}
	if nodes == nil {
		return
	}

	s.nodesMu.Lock()
	s.nodes = nodes
	s.nodesMu.Unlock()
	log.Printf("Loaded %d nodes from registry", len(nodes))
}

// saveNodes persists the node registry to disk atomically: a crash mid-write must
// not leave a truncated registry for the next start to load.
func (s *Server) saveNodes() {
	s.saveMu.Lock()
	defer s.saveMu.Unlock()

	s.nodesMu.RLock()
	data, err := json.MarshalIndent(s.nodes, "", "  ")
	s.nodesMu.RUnlock()

	if err != nil {
		log.Printf("Warning: Failed to marshal nodes registry: %v", err)
		return
	}

	if err := writeFileAtomic(s.nodesFile, data); err != nil {
		log.Printf("Warning: Failed to save nodes registry: %v", err)
	}
}

// writeFileAtomic writes via a temp file in the same directory and renames it into
// place. os.CreateTemp creates the file with mode 0600.
func writeFileAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once renamed

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// periodicSaveNodes saves nodes periodically
func (s *Server) periodicSaveNodes(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			s.saveNodes() // Final save on shutdown
			return
		case <-ticker.C:
			s.saveNodes()
		}
	}
}

// watchConfigChanges updates the config version when ConfigMaps change.
// Watches both service-registry AND domain-registry so VPS nodes detect
// routing changes (e.g., adding a public domain) even when service-registry
// hasn't changed.
func (s *Server) watchConfigChanges(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.checkConfigChanges(ctx)
		}
	}
}

// rvUnknown marks a resourceVersion that could not be read at startup. Whatever is
// read next differs from it, so a change made in the meantime can't be missed. The
// cost is one extra version bump, and agents re-applying the same config.
const rvUnknown = "unknown"

// primeResourceVersions records where the ConfigMaps stand when the API starts, so a
// change before the first tick of the watcher counts as a change.
func (s *Server) primeResourceVersions(ctx context.Context) {
	s.primeResourceVersion(ctx, "service-registry", &s.lastServiceRV)
	s.primeResourceVersion(ctx, "domain-registry", &s.lastDomainRV)
}

func (s *Server) primeResourceVersion(ctx context.Context, configMap string, last *string) {
	s.resourceVersionChanged(ctx, configMap, last)
	if *last == "" {
		*last = rvUnknown
	}
}

// checkConfigChanges does one watch tick. A failed or blank read changes nothing:
// the version only advances when a real new resourceVersion was seen.
func (s *Server) checkConfigChanges(ctx context.Context) {
	serviceChanged := s.resourceVersionChanged(ctx, "service-registry", &s.lastServiceRV)
	domainChanged := s.resourceVersionChanged(ctx, "domain-registry", &s.lastDomainRV)

	if serviceChanged || domainChanged {
		v := fmt.Sprintf("v%d", time.Now().UnixNano())
		s.setVersion(v)
		log.Printf("Config changed, new version: %s", v)
	}
}

func (s *Server) resourceVersionChanged(ctx context.Context, configMap string, last *string) bool {
	ctx, cancel := context.WithTimeout(ctx, kubectlTimeout)
	defer cancel()

	output, err := s.kubectl(ctx, "get", "configmap", "-n", "kube-system", configMap,
		"-o", "jsonpath={.metadata.resourceVersion}")
	if err != nil {
		return false
	}
	rv := strings.TrimSpace(string(output))
	if rv == "" {
		return false
	}
	changed := *last != "" && rv != *last
	if changed {
		log.Printf("%s changed (rv: %s -> %s)", configMap, *last, rv)
	}
	*last = rv
	return changed
}

// discoverTailscaleIP finds this host's Tailscale IPv4 address. The interface is
// checked first because it needs nothing but the kernel. The CLI covers renamed
// interfaces.
func discoverTailscaleIP(ctx context.Context) (net.IP, error) {
	if iface, err := net.InterfaceByName("tailscale0"); err == nil {
		if addrs, err := iface.Addrs(); err == nil {
			for _, addr := range addrs {
				if ipnet, ok := addr.(*net.IPNet); ok && ipnet.IP.To4() != nil && tailscaleV4Net.Contains(ipnet.IP) {
					return ipnet.IP, nil
				}
			}
		}
	}

	ctx, cancel := context.WithTimeout(ctx, kubectlTimeout)
	defer cancel()
	output, err := exec.CommandContext(ctx, "tailscale", "ip", "-4").Output()
	if err != nil {
		return nil, fmt.Errorf("tailscale ip -4: %w", err)
	}
	for _, line := range strings.Fields(string(output)) {
		if ip := net.ParseIP(line); ip != nil && ip.To4() != nil && tailscaleV4Net.Contains(ip) {
			return ip, nil
		}
	}
	return nil, errors.New("tailscale reported no IPv4 address in 100.64.0.0/10")
}

// serveOnTailscale keeps trying to listen on the Tailscale IP. tailscaled can come
// up after this service, so loopback serves in the meantime and the tailnet
// listener joins as soon as the address exists.
func serveOnTailscale(ctx context.Context, srv *http.Server, port int, errs chan<- error) {
	logged := false
	for {
		ip, err := discoverTailscaleIP(ctx)
		if err == nil {
			addr := net.JoinHostPort(ip.String(), fmt.Sprintf("%d", port))
			var ln net.Listener
			ln, err = net.Listen("tcp", addr)
			if err == nil {
				log.Printf("Listening on %s", addr)
				errs <- srv.Serve(ln)
				return
			}
		}
		if !logged {
			log.Printf("Tailscale address not ready, nodes cannot reach this API yet: %v (retrying)", err)
			logged = true
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(tailscaleRetryWait):
		}
	}
}

func main() {
	// Parse flags
	port := flag.Int("port", 8443, "Port to listen on")
	bindIP := flag.String("bind", bindModeTailscale, "IP to bind to, or 'tailscale' for loopback plus this host's Tailscale IP")
	tokenFile := flag.String("token-file", "/etc/mynodeone/api-token", "Path to API token file")
	requireTailscale := flag.Bool("require-tailscale", true, "Require a tailnet or loopback source address")
	flag.Parse()

	// Load API token. Running without one would open node removal and heartbeats
	// to every host that can reach the port, so refuse to start.
	data, err := os.ReadFile(*tokenFile)
	if err != nil {
		log.Fatalf("Cannot read API token file %s: %v. Refusing to start without authentication.", *tokenFile, err)
	}
	apiToken := strings.TrimSpace(string(data))
	if apiToken == "" {
		log.Fatalf("API token file %s is empty. Refusing to start without authentication.", *tokenFile)
	}
	log.Printf("API token loaded from %s", *tokenFile)

	// Create server
	cfg := Config{
		Port:                   *port,
		BindIP:                 *bindIP,
		APIToken:               apiToken,
		HeartbeatOnlineSeconds: 120, // 2 minutes
		HeartbeatStaleSeconds:  600, // 10 minutes
		RequireTailscaleIP:     *requireTailscale,
	}
	server := NewServer(cfg)

	// Set up routes
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/health", server.handleHealth)

	// Config endpoints
	mux.HandleFunc("/api/v1/config/vps/traefik-config", server.authMiddleware(server.metricsMiddleware(server.handleTraefikConfig)))
	mux.HandleFunc("/api/v1/config/", server.authMiddleware(server.metricsMiddleware(server.handleConfig)))

	// Node management endpoints
	mux.HandleFunc("/api/v1/heartbeat", server.authMiddleware(server.metricsMiddleware(server.handleHeartbeat)))
	mux.HandleFunc("/api/v1/nodes", server.authMiddleware(server.metricsMiddleware(server.handleNodes)))
	mux.HandleFunc("/api/v1/nodes/", server.authMiddleware(server.metricsMiddleware(server.handleNodeDelete)))

	// Metrics endpoint
	mux.Handle("/metrics", promhttp.Handler())

	// Create HTTP server. WriteTimeout covers the kubectl calls behind a config
	// request, which can take up to twice kubectlTimeout.
	httpServer := &http.Server{
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
	}

	// Start config watcher and periodic node save
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server.primeResourceVersions(ctx)
	go server.watchConfigChanges(ctx)
	go server.periodicSaveNodes(ctx)

	// Handle shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	shutdownDone := make(chan struct{})
	go func() {
		<-sigChan
		log.Println("Shutting down...")
		cancel()
		httpServer.Shutdown(context.Background())
		server.saveNodes()
		close(shutdownDone)
	}()

	log.Printf("MyNodeOne Config API Server starting (bind=%s port=%d)", cfg.BindIP, cfg.Port)
	log.Printf("Tailscale IP required: %v", cfg.RequireTailscaleIP)

	serveErrs := make(chan error, 2)
	if cfg.BindIP == bindModeTailscale {
		loopback := net.JoinHostPort("127.0.0.1", fmt.Sprintf("%d", cfg.Port))
		ln, err := net.Listen("tcp", loopback)
		if err != nil {
			log.Fatalf("Cannot listen on %s: %v", loopback, err)
		}
		log.Printf("Listening on %s", loopback)
		go func() { serveErrs <- httpServer.Serve(ln) }()
		go serveOnTailscale(ctx, httpServer, cfg.Port, serveErrs)
	} else {
		addr := net.JoinHostPort(cfg.BindIP, fmt.Sprintf("%d", cfg.Port))
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			log.Fatalf("Cannot listen on %s: %v", addr, err)
		}
		log.Printf("Listening on %s", addr)
		go func() { serveErrs <- httpServer.Serve(ln) }()
	}

	// Any listener ending for a reason other than Shutdown is fatal, so systemd restarts us.
	if err := <-serveErrs; err != http.ErrServerClosed {
		log.Fatalf("Server error: %v", err)
	}
	<-shutdownDone
}
