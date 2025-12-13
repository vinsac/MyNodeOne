// MyNodeOne Config API Server
//
// A lightweight HTTP server that serves configuration to nodes in the cluster.
// Nodes poll this server for config updates and send heartbeats.
//
// Endpoints:
//   GET  /api/v1/config/{node-type}  - Get config for node type (laptop, vps, worker)
//   POST /api/v1/heartbeat           - Node reports its status
//   GET  /api/v1/nodes               - List all nodes and their status
//   GET  /api/v1/health              - Health check
//
// Authentication:
//   - Tailscale IP verification (only 100.x.x.x can connect)
//   - API token in X-API-Token header (defense in depth)

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

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
type TraefikRoute struct {
	Service string `json:"service"`
	Domain  string `json:"domain"`
	Backend string `json:"backend"`
}

// ConfigResponse is the response for /api/v1/config/{type}
type ConfigResponse struct {
	Version    string         `json:"version"`
	Timestamp  time.Time      `json:"timestamp"`
	DNSEntries []DNSEntry     `json:"dns_entries,omitempty"`
	Routes     []TraefikRoute `json:"routes,omitempty"`
}

// NodesResponse is the response for /api/v1/nodes
type NodesResponse struct {
	Nodes []Node `json:"nodes"`
}

// Server holds the API server state
type Server struct {
	config       Config
	nodes        map[string]*Node
	nodesMu      sync.RWMutex
	configVer    string
	nodesFile    string
}

const defaultNodesFile = "/etc/mynodeone/nodes-registry.json"

func NewServer(cfg Config) *Server {
	s := &Server{
		config:    cfg,
		nodes:     make(map[string]*Node),
		configVer: fmt.Sprintf("v%d", time.Now().Unix()),
		nodesFile: defaultNodesFile,
	}
	// Load persisted nodes
	s.loadNodes()
	return s
}

// Middleware: Verify Tailscale IP and API token
func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Get client IP
		clientIP, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			clientIP = r.RemoteAddr
		}

		// Check Tailscale IP (100.x.x.x range)
		if s.config.RequireTailscaleIP {
			if !strings.HasPrefix(clientIP, "100.") && clientIP != "127.0.0.1" && clientIP != "::1" {
				log.Printf("DENIED: Non-Tailscale IP %s tried to access %s", clientIP, r.URL.Path)
				http.Error(w, "Forbidden: Must connect via Tailscale", http.StatusForbidden)
				return
			}
		}

		// Check API token if configured
		if s.config.APIToken != "" {
			token := r.Header.Get("X-API-Token")
			if token != s.config.APIToken {
				log.Printf("DENIED: Invalid API token from %s", clientIP)
				http.Error(w, "Unauthorized: Invalid API token", http.StatusUnauthorized)
				return
			}
		}

		next(w, r)
	}
}

// GET /api/v1/health
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":      "ok",
		"server_time": time.Now().UTC(),
		"version":     "1.0.0",
	})
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

	// Get node name from header (for logging)
	nodeName := r.Header.Get("X-Node-Name")
	clientIP, _, _ := net.SplitHostPort(r.RemoteAddr)
	log.Printf("Config request: type=%s node=%s ip=%s", nodeType, nodeName, clientIP)

	// Fetch config from Kubernetes ConfigMaps
	response, err := s.getConfigForNodeType(nodeType)
	if err != nil {
		log.Printf("Error getting config: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// POST /api/v1/heartbeat
func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req HeartbeatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	if req.NodeName == "" || req.NodeType == "" {
		http.Error(w, "node_name and node_type required", http.StatusBadRequest)
		return
	}

	// Get client IP if not provided
	if req.NodeIP == "" {
		req.NodeIP, _, _ = net.SplitHostPort(r.RemoteAddr)
	}

	// Update node registry
	s.nodesMu.Lock()
	isNewNode := s.nodes[req.NodeName] == nil
	s.nodes[req.NodeName] = &Node{
		Name:          req.NodeName,
		Type:          req.NodeType,
		IP:            req.NodeIP,
		Status:        "online",
		LastHeartbeat: time.Now(),
		ConfigVersion: req.ConfigVersion,
		UptimeSeconds: req.UptimeSeconds,
	}
	s.nodesMu.Unlock()

	// Persist immediately for new nodes
	if isNewNode {
		s.saveNodes()
		log.Printf("New node registered: %s (%s) at %s", req.NodeName, req.NodeType, req.NodeIP)
	} else {
		log.Printf("Heartbeat: node=%s type=%s ip=%s config=%s",
			req.NodeName, req.NodeType, req.NodeIP, req.ConfigVersion)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":      "ok",
		"server_time": time.Now().UTC(),
	})
}

// DELETE /api/v1/nodes/{name} - Remove a node from registry
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

	s.nodesMu.Lock()
	if _, exists := s.nodes[nodeName]; exists {
		delete(s.nodes, nodeName)
		s.nodesMu.Unlock()
		s.saveNodes() // Persist change
		log.Printf("Node removed: %s", nodeName)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "removed", "node": nodeName})
	} else {
		s.nodesMu.Unlock()
		http.Error(w, "Node not found", http.StatusNotFound)
	}
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

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(NodesResponse{Nodes: nodes})
}

// getConfigForNodeType fetches config from Kubernetes ConfigMaps
func (s *Server) getConfigForNodeType(nodeType string) (*ConfigResponse, error) {
	response := &ConfigResponse{
		Version:   s.configVer,
		Timestamp: time.Now().UTC(),
	}

	switch nodeType {
	case "laptop", "worker":
		// Fetch DNS entries from service-registry ConfigMap
		entries, err := s.getDNSEntries()
		if err != nil {
			return nil, err
		}
		response.DNSEntries = entries

	case "vps":
		// Fetch routes from service-registry ConfigMap
		routes, err := s.getTraefikRoutes()
		if err != nil {
			return nil, err
		}
		response.Routes = routes

	default:
		return nil, fmt.Errorf("unknown node type: %s", nodeType)
	}

	return response, nil
}

// getDNSEntries fetches DNS entries from service-registry ConfigMap
func (s *Server) getDNSEntries() ([]DNSEntry, error) {
	// Run kubectl to get service registry
	cmd := exec.Command("kubectl", "get", "configmap", "-n", "kube-system",
		"service-registry", "-o", "jsonpath={.data.services\\.json}")
	output, err := cmd.Output()
	if err != nil {
		// ConfigMap might not exist yet
		log.Printf("Warning: Could not get service-registry: %v", err)
		return []DNSEntry{}, nil
	}

	if len(output) == 0 {
		return []DNSEntry{}, nil
	}

	// Parse the JSON
	var services map[string]interface{}
	if err := json.Unmarshal(output, &services); err != nil {
		return nil, fmt.Errorf("failed to parse service registry: %v", err)
	}

	// Extract DNS entries from flat registry format
	// Format: {"servicename": {"subdomain": "x", "ip": "y", ...}, ...}
	entries := []DNSEntry{}
	for name, svc := range services {
		if svcMap, ok := svc.(map[string]interface{}); ok {
			ip, _ := svcMap["ip"].(string)
			subdomain, _ := svcMap["subdomain"].(string)
			if ip != "" && subdomain != "" {
				entries = append(entries, DNSEntry{
					Name: subdomain,
					IP:   ip,
				})
			}
		}
	}

	return entries, nil
}

// getTraefikRoutes fetches routes for VPS from service-registry ConfigMap
func (s *Server) getTraefikRoutes() ([]TraefikRoute, error) {
	// Run kubectl to get service registry
	cmd := exec.Command("kubectl", "get", "configmap", "-n", "kube-system",
		"service-registry", "-o", "jsonpath={.data.services\\.json}")
	output, err := cmd.Output()
	if err != nil {
		log.Printf("Warning: Could not get service-registry: %v", err)
		return []TraefikRoute{}, nil
	}

	if len(output) == 0 {
		return []TraefikRoute{}, nil
	}

	// Parse the JSON
	var services map[string]interface{}
	if err := json.Unmarshal(output, &services); err != nil {
		return nil, fmt.Errorf("failed to parse service registry: %v", err)
	}

	// Extract routes for public services from flat registry format
	// Format: {"servicename": {"subdomain": "x", "public": true, ...}, ...}
	routes := []TraefikRoute{}
	for name, svc := range services {
		if svcMap, ok := svc.(map[string]interface{}); ok {
			// Only include public services
			isPublic, _ := svcMap["public"].(bool)
			if !isPublic {
				continue
			}

			ip, _ := svcMap["ip"].(string)
			port, _ := svcMap["port"].(float64)
			domain, _ := svcMap["domain"].(string)

			if ip != "" && domain != "" {
				backend := ip
				if port > 0 {
					backend = fmt.Sprintf("%s:%.0f", ip, port)
				}
				routes = append(routes, TraefikRoute{
					Service: name,
					Domain:  domain,
					Backend: backend,
				})
			}
		}
	}

	return routes, nil
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

	s.nodesMu.Lock()
	s.nodes = nodes
	s.nodesMu.Unlock()
	log.Printf("Loaded %d nodes from registry", len(nodes))
}

// saveNodes persists the node registry to disk
func (s *Server) saveNodes() {
	s.nodesMu.RLock()
	data, err := json.MarshalIndent(s.nodes, "", "  ")
	s.nodesMu.RUnlock()

	if err != nil {
		log.Printf("Warning: Failed to marshal nodes registry: %v", err)
		return
	}

	if err := os.WriteFile(s.nodesFile, data, 0600); err != nil {
		log.Printf("Warning: Failed to save nodes registry: %v", err)
	}
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

// updateConfigVersion updates the config version when ConfigMaps change
func (s *Server) watchConfigChanges(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	lastHash := ""

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Get current config hash
			cmd := exec.Command("kubectl", "get", "configmap", "-n", "kube-system",
				"service-registry", "-o", "jsonpath={.metadata.resourceVersion}")
			output, err := cmd.Output()
			if err != nil {
				continue
			}

			hash := string(output)
			if hash != lastHash && lastHash != "" {
				// Config changed, update version
				s.configVer = fmt.Sprintf("v%d", time.Now().Unix())
				log.Printf("Config changed, new version: %s", s.configVer)
			}
			lastHash = hash
		}
	}
}

func main() {
	// Parse flags
	port := flag.Int("port", 8443, "Port to listen on")
	bindIP := flag.String("bind", "0.0.0.0", "IP to bind to")
	tokenFile := flag.String("token-file", "/etc/mynodeone/api-token", "Path to API token file")
	requireTailscale := flag.Bool("require-tailscale", true, "Require Tailscale IP (100.x.x.x)")
	flag.Parse()

	// Load API token
	apiToken := ""
	if data, err := os.ReadFile(*tokenFile); err == nil {
		apiToken = strings.TrimSpace(string(data))
		log.Printf("API token loaded from %s", *tokenFile)
	} else {
		log.Printf("Warning: No API token file at %s, running without token auth", *tokenFile)
	}

	// Create server
	cfg := Config{
		Port:                   *port,
		BindIP:                 *bindIP,
		APIToken:               apiToken,
		HeartbeatOnlineSeconds: 120,  // 2 minutes
		HeartbeatStaleSeconds:  600,  // 10 minutes
		RequireTailscaleIP:     *requireTailscale,
	}
	server := NewServer(cfg)

	// Set up routes
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/health", server.handleHealth)
	mux.HandleFunc("/api/v1/config/", server.authMiddleware(server.handleConfig))
	mux.HandleFunc("/api/v1/heartbeat", server.authMiddleware(server.handleHeartbeat))
	mux.HandleFunc("/api/v1/nodes", server.authMiddleware(server.handleNodes))
	mux.HandleFunc("/api/v1/nodes/", server.authMiddleware(server.handleNodeDelete))

	// Create HTTP server
	addr := fmt.Sprintf("%s:%d", cfg.BindIP, cfg.Port)
	httpServer := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	// Start config watcher and periodic node save
	ctx, cancel := context.WithCancel(context.Background())
	go server.watchConfigChanges(ctx)
	go server.periodicSaveNodes(ctx)

	// Handle shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigChan
		log.Println("Shutting down...")
		cancel()
		httpServer.Shutdown(context.Background())
	}()

	// Start server
	log.Printf("MyNodeOne Config API Server starting on %s", addr)
	log.Printf("Tailscale IP required: %v", cfg.RequireTailscaleIP)
	log.Printf("API token auth: %v", cfg.APIToken != "")

	if err := httpServer.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatalf("Server error: %v", err)
	}
}
