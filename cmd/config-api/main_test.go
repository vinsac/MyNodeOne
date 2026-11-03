package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

func TestMain(m *testing.M) {
	log.SetOutput(io.Discard)
	os.Exit(m.Run())
}

// fakeKubectl answers by ConfigMap name and requested jsonpath. A missing
// response means NotFound, the same failure kubectl reports.
type fakeResponse struct {
	out string
	err error
}

type fakeKubectl map[string]fakeResponse

func (f fakeKubectl) run(_ context.Context, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	for _, key := range []string{"service-registry", "domain-registry"} {
		if !strings.Contains(joined, key) {
			continue
		}
		lookup := key
		if strings.Contains(joined, "resourceVersion") {
			lookup = key + "/rv"
		}
		if resp, ok := f[lookup]; ok {
			return []byte(resp.out), resp.err
		}
		return nil, errors.New("Error from server (NotFound): configmaps not found")
	}
	return nil, errors.New("unexpected kubectl call: " + joined)
}

func newTestServer(t *testing.T, f fakeKubectl) *Server {
	t.Helper()
	// Built directly: NewServer would load the real nodes file from /etc.
	return &Server{
		config: Config{
			APIToken:               "test-token",
			HeartbeatOnlineSeconds: 120,
			HeartbeatStaleSeconds:  600,
			RequireTailscaleIP:     true,
		},
		nodes:     make(map[string]*Node),
		nodesFile: filepath.Join(t.TempDir(), "nodes.json"),
		kubectl:   f.run,
		configVer: "v-initial",
	}
}

const (
	liveRegistry = `{"llmapi":{"local_name":"llm","namespace":"llmapi","service":"llmapi","ip":"100.72.41.10","port":80,"public":true}}`
	liveRouting  = `{"llmapi":{"expose":["llmapi.example.com"]}}`
)

func TestConfigFailureSemantics(t *testing.T) {
	boom := errors.New("connection refused")
	tests := []struct {
		name       string
		nodeType   string
		kubectl    fakeKubectl
		wantStatus int
		wantField  string // field that must be an explicit array
		wantLen    int
	}{
		{"vps: kubectl fails", "vps", fakeKubectl{"service-registry": {err: boom}}, 503, "", 0},
		{"vps: configmap not found", "vps", fakeKubectl{}, 503, "", 0},
		{"vps: exit 0 with blank output", "vps", fakeKubectl{"service-registry": {out: ""}}, 503, "", 0},
		{"vps: whitespace output", "vps", fakeKubectl{"service-registry": {out: " \n"}}, 503, "", 0},
		{"vps: invalid JSON", "vps", fakeKubectl{"service-registry": {out: "{nope"}}, 503, "", 0},
		{"vps: JSON null", "vps", fakeKubectl{"service-registry": {out: "null"}}, 503, "", 0},
		{"vps: JSON array", "vps", fakeKubectl{"service-registry": {out: "[]"}}, 503, "", 0},
		{"vps: public service, domain-registry fails", "vps", fakeKubectl{
			"service-registry": {out: liveRegistry},
			"domain-registry":  {err: boom},
		}, 503, "", 0},
		{"vps: public service, routing blank", "vps", fakeKubectl{
			"service-registry": {out: liveRegistry},
			"domain-registry":  {out: ""},
		}, 503, "", 0},
		{"vps: public service, routing invalid", "vps", fakeKubectl{
			"service-registry": {out: liveRegistry},
			"domain-registry":  {out: "<html>"},
		}, 503, "", 0},
		{"vps: confirmed empty registry", "vps", fakeKubectl{"service-registry": {out: "{}"}}, 200, "routes", 0},
		{"vps: only private services, no domain-registry", "vps", fakeKubectl{
			"service-registry": {out: `{"a":{"local_name":"a","namespace":"n","service":"a","ip":"100.72.41.10","port":80,"public":false}}`},
		}, 200, "routes", 0},
		{"vps: public but routing confirmed empty", "vps", fakeKubectl{
			"service-registry": {out: liveRegistry},
			"domain-registry":  {out: "{}"},
		}, 200, "routes", 0},
		{"vps: one route", "vps", fakeKubectl{
			"service-registry": {out: liveRegistry},
			"domain-registry":  {out: liveRouting},
		}, 200, "routes", 1},
		{"laptop: kubectl fails", "laptop", fakeKubectl{"service-registry": {err: boom}}, 503, "", 0},
		{"worker: blank output", "worker", fakeKubectl{"service-registry": {out: ""}}, 503, "", 0},
		{"laptop: confirmed empty", "laptop", fakeKubectl{"service-registry": {out: "{}"}}, 200, "dns_entries", 0},
		{"laptop: one entry", "laptop", fakeKubectl{"service-registry": {out: liveRegistry}}, 200, "dns_entries", 1},
		{"unknown node type", "mainframe", fakeKubectl{"service-registry": {out: "{}"}}, 404, "", 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newTestServer(t, tt.kubectl)
			before := s.version()

			req := httptest.NewRequest(http.MethodGet, "/api/v1/config/"+tt.nodeType, nil)
			rec := httptest.NewRecorder()
			s.handleConfig(rec, req)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d, body %q", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if s.version() != before {
				t.Errorf("version moved from %s to %s", before, s.version())
			}
			if tt.wantStatus != http.StatusOK {
				var parsed map[string]interface{}
				if json.Unmarshal(rec.Body.Bytes(), &parsed) == nil {
					t.Errorf("error body must not parse as a config: %q", rec.Body.String())
				}
				return
			}

			var body map[string]json.RawMessage
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("invalid JSON: %v", err)
			}
			raw, present := body[tt.wantField]
			if !present {
				t.Fatalf("field %q absent from %s", tt.wantField, rec.Body.String())
			}
			var list []json.RawMessage
			if err := json.Unmarshal(raw, &list); err != nil || list == nil {
				t.Fatalf("field %q = %s, want an explicit array", tt.wantField, raw)
			}
			if len(list) != tt.wantLen {
				t.Errorf("len(%s) = %d, want %d", tt.wantField, len(list), tt.wantLen)
			}
			other := map[string]string{"routes": "dns_entries", "dns_entries": "routes"}[tt.wantField]
			if _, present := body[other]; present {
				t.Errorf("field %q must be absent for node type %s", other, tt.nodeType)
			}
		})
	}
}

// TestWriteContractFixtures saves real handler responses for
// scripts/tests/routing/run-tests.sh, which feeds them to the shell clients. Without
// this, the clients would only ever be tested against hand-written JSON and YAML.
func TestWriteContractFixtures(t *testing.T) {
	dir := os.Getenv("ROUTING_CONTRACT_DIR")
	if dir == "" {
		t.Skip("ROUTING_CONTRACT_DIR not set")
	}
	scenarios := map[string]fakeKubectl{
		"live":   {"service-registry": {out: liveRegistry}, "domain-registry": {out: liveRouting}},
		"empty":  {"service-registry": {out: "{}"}},
		"broken": {"service-registry": {err: errors.New("connection refused")}},
	}
	for name, kubectl := range scenarios {
		s := newTestServer(t, kubectl)
		target := filepath.Join(dir, name)
		if err := os.MkdirAll(target, 0o755); err != nil {
			t.Fatal(err)
		}
		// File names follow the curl stub: the URL path with / replaced by _.
		save := func(path string, handler http.HandlerFunc) {
			rec := httptest.NewRecorder()
			handler(rec, httptest.NewRequest(http.MethodGet, path, nil))
			key := filepath.Join(target, strings.ReplaceAll(path, "/", "_"))
			if err := os.WriteFile(key+".body", rec.Body.Bytes(), 0o644); err != nil {
				t.Fatal(err)
			}
			code := strconv.Itoa(rec.Code) + "\n"
			if err := os.WriteFile(key+".code", []byte(code), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		save("/api/v1/health", s.handleHealth)
		save("/api/v1/config/vps", s.handleConfig)
		save("/api/v1/config/laptop", s.handleConfig)
		save("/api/v1/config/vps/traefik-config", s.handleTraefikConfig)
	}
}

func TestTraefikConfigFailureIs503(t *testing.T) {
	s := newTestServer(t, fakeKubectl{"service-registry": {err: errors.New("down")}})
	rec := httptest.NewRecorder()
	s.handleTraefikConfig(rec, httptest.NewRequest(http.MethodGet, "/api/v1/config/vps/traefik-config", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "http:") {
		t.Errorf("error body looks like YAML config: %q", rec.Body.String())
	}
}

func TestTraefikConfigEmptyHasNoRouters(t *testing.T) {
	s := newTestServer(t, fakeKubectl{"service-registry": {out: "{}"}})
	rec := httptest.NewRecorder()
	s.handleTraefikConfig(rec, httptest.NewRequest(http.MethodGet, "/api/v1/config/vps/traefik-config", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var cfg TraefikConfig
	if err := yaml.Unmarshal(rec.Body.Bytes(), &cfg); err != nil {
		t.Fatalf("invalid YAML: %v", err)
	}
	if len(cfg.HTTP.Routers) != 0 {
		t.Errorf("routers = %v, want none", cfg.HTTP.Routers)
	}
}

func TestVersionAdvancesOnlyOnRealChange(t *testing.T) {
	boom := errors.New("down")
	steps := []struct {
		name        string
		kubectl     fakeKubectl
		wantAdvance bool
	}{
		{"first read sets baseline", fakeKubectl{"service-registry/rv": {out: "10"}, "domain-registry/rv": {out: "20"}}, false},
		{"unchanged", fakeKubectl{"service-registry/rv": {out: "10"}, "domain-registry/rv": {out: "20"}}, false},
		{"kubectl failure", fakeKubectl{"service-registry/rv": {err: boom}, "domain-registry/rv": {err: boom}}, false},
		{"blank output", fakeKubectl{"service-registry/rv": {out: ""}, "domain-registry/rv": {out: "  "}}, false},
		{"recovered, same resourceVersion", fakeKubectl{"service-registry/rv": {out: "10"}, "domain-registry/rv": {out: "20"}}, false},
		{"service-registry changed", fakeKubectl{"service-registry/rv": {out: "11"}, "domain-registry/rv": {out: "20"}}, true},
		{"domain-registry changed", fakeKubectl{"service-registry/rv": {out: "11"}, "domain-registry/rv": {out: "21"}}, true},
	}

	s := newTestServer(t, fakeKubectl{})
	for _, step := range steps {
		before := s.version()
		s.kubectl = step.kubectl.run
		s.checkConfigChanges(context.Background())
		if advanced := s.version() != before; advanced != step.wantAdvance {
			t.Errorf("%s: advanced = %v, want %v", step.name, advanced, step.wantAdvance)
		}
	}
}

func TestChangeBeforeFirstTickAdvancesVersion(t *testing.T) {
	s := newTestServer(t, fakeKubectl{"service-registry/rv": {out: "10"}, "domain-registry/rv": {out: "20"}})
	s.primeResourceVersions(context.Background())
	before := s.version()

	s.kubectl = fakeKubectl{"service-registry/rv": {out: "11"}, "domain-registry/rv": {out: "20"}}.run
	s.checkConfigChanges(context.Background())
	if s.version() == before {
		t.Error("a change between startup and the first tick did not advance the version")
	}
}

func TestNoChangeAfterStartupKeepsVersion(t *testing.T) {
	s := newTestServer(t, fakeKubectl{"service-registry/rv": {out: "10"}, "domain-registry/rv": {out: "20"}})
	s.primeResourceVersions(context.Background())
	before := s.version()
	s.checkConfigChanges(context.Background())
	if s.version() != before {
		t.Error("the version advanced with nothing changed")
	}
}

func TestFailedReadAtStartupAdvancesOnFirstGoodRead(t *testing.T) {
	boom := errors.New("down")
	s := newTestServer(t, fakeKubectl{"service-registry/rv": {err: boom}, "domain-registry/rv": {err: boom}})
	s.primeResourceVersions(context.Background())
	before := s.version()

	s.checkConfigChanges(context.Background())
	if s.version() != before {
		t.Error("still failing: the version advanced")
	}

	s.kubectl = fakeKubectl{"service-registry/rv": {out: "10"}, "domain-registry/rv": {out: "20"}}.run
	s.checkConfigChanges(context.Background())
	if s.version() == before {
		t.Error("anything could have changed while reads failed; the version must advance")
	}
	after := s.version()
	s.checkConfigChanges(context.Background())
	if s.version() != after {
		t.Error("advanced again with nothing changed")
	}
}

func TestRouterNamesStayTheSameWithoutACollision(t *testing.T) {
	s := newTestServer(t, fakeKubectl{})
	config := s.generateTraefikConfig([]TraefikRoute{
		{Service: "immich", Domain: "photos.example.com", Backend: "100.64.1.1:80"},
		{Service: "chat", Domain: "chat.example.com", Backend: "100.64.1.2:80"},
	})
	for _, want := range []string{
		"immich-photos-example-com", "immich-photos-example-com-http",
		"chat-chat-example-com", "chat-chat-example-com-http",
	} {
		if _, ok := config.HTTP.Routers[want]; !ok {
			t.Errorf("router %q missing; a rename makes Traefik rebuild it", want)
		}
	}
}

func TestRouterNameCollisionKeepsBothRoutes(t *testing.T) {
	s := newTestServer(t, fakeKubectl{})
	routes := []TraefikRoute{
		{Service: "chat-api", Domain: "example.com", Backend: "100.64.1.1:80"},
		{Service: "chat", Domain: "api.example.com", Backend: "100.64.1.2:80"},
		{Service: "other", Domain: "other.example.com", Backend: "100.64.1.3:80"},
	}
	config := s.generateTraefikConfig(routes)
	if len(config.HTTP.Routers) != 2*len(routes) {
		t.Fatalf("got %d routers, want %d: %v", len(config.HTTP.Routers), 2*len(routes), config.HTTP.Routers)
	}
	services := map[string]bool{}
	for _, router := range config.HTTP.Routers {
		services[router.Service] = true
	}
	if !services["chat-api-service"] || !services["chat-service"] {
		t.Errorf("a route was lost: services %v", services)
	}
	if _, ok := config.HTTP.Routers["other-other-example-com"]; !ok {
		t.Error("a route with no collision was renamed")
	}

	// The order routes arrive in must not rename anything.
	again := s.generateTraefikConfig([]TraefikRoute{routes[2], routes[1], routes[0]})
	for name := range config.HTTP.Routers {
		if _, ok := again.HTTP.Routers[name]; !ok {
			t.Errorf("router %q renamed when the order changed", name)
		}
	}
}

func TestRouterNameClashWithAnHTTPRouter(t *testing.T) {
	s := newTestServer(t, fakeKubectl{})
	routes := []TraefikRoute{
		{Service: "a", Domain: "b.example.com", Backend: "100.64.1.1:80"},
		{Service: "a-b-example", Domain: "com-http", Backend: "100.64.1.2:80"},
	}
	config := s.generateTraefikConfig(routes)
	if len(config.HTTP.Routers) != 2*len(routes) {
		t.Errorf("got %d routers, want %d: %v", len(config.HTTP.Routers), 2*len(routes), config.HTTP.Routers)
	}
}

// An external app: the key is the app, the Service is named differently, and routing is
// filed under the name it was published with. Then the same thing after migration.
func TestExternalAppKeepsItsRoute(t *testing.T) {
	const entry = `{"myapp/myapp-web":{"namespace":"myapp","service":"myapp-web","ip":"100.64.1.7","port":80,"legacy_key":"myapp","public":true}}`
	for name, routing := range map[string]string{
		"filed under the old name": `{"myapp":{"expose":["app.example.com"]}}`,
		"filed under the new key":  `{"myapp/myapp-web":{"expose":["app.example.com"]}}`,
	} {
		routes := routesFor(t, entry, routing)
		if len(routes) != 1 || routes[0].Domain != "app.example.com" {
			t.Errorf("%s: routes = %+v", name, routes)
		}
	}
}

func routesFor(t *testing.T, services, routing string) []TraefikRoute {
	t.Helper()
	s := newTestServer(t, fakeKubectl{"service-registry": {out: services}, "domain-registry": {out: routing}})
	routes, err := s.getTraefikRoutes(context.Background())
	if err != nil {
		t.Fatalf("getTraefikRoutes: %v", err)
	}
	return routes
}

func TestRegistryKeyCollisions(t *testing.T) {
	frontend := func(ns, ip string, public bool, extra string) string {
		pub := "false"
		if public {
			pub = "true"
		}
		return `"` + ns + `/frontend":{"local_name":"` + ns + `","namespace":"` + ns + `","service":"frontend","ip":"` + ip + `","port":80,"public":` + pub + extra + `}`
	}

	tests := []struct {
		name     string
		services string
		routing  string
		want     map[string]string // domain -> backend
		wantIDs  map[string]string // domain -> route ID
	}{
		{
			name:     "private namesake does not inherit a bare routing key",
			services: `{` + frontend("a", "100.64.0.1", true, "") + `,` + frontend("b", "100.64.0.2", false, "") + `}`,
			routing:  `{"frontend":{"expose":["a.example.com"]}}`,
			want:     map[string]string{"a.example.com": "100.64.0.1:80"},
		},
		{
			name:     "two public namesakes refuse an ambiguous bare routing key",
			services: `{` + frontend("a", "100.64.0.1", true, "") + `,` + frontend("b", "100.64.0.2", true, "") + `}`,
			routing:  `{"frontend":{"expose":["shared.example.com"]}}`,
			want:     map[string]string{},
		},
		{
			name:     "namespaced routing keys route each service to its own backend",
			services: `{` + frontend("a", "100.64.0.1", true, "") + `,` + frontend("b", "100.64.0.2", true, "") + `}`,
			routing:  `{"a/frontend":{"expose":["a.example.com"]},"b/frontend":{"expose":["b.example.com"]}}`,
			want:     map[string]string{"a.example.com": "100.64.0.1:80", "b.example.com": "100.64.0.2:80"},
			wantIDs:  map[string]string{"a.example.com": "a-frontend", "b.example.com": "b-frontend"},
		},
		{
			name:     "own routing key beats a bare one",
			services: `{` + frontend("a", "100.64.0.1", true, "") + `}`,
			routing:  `{"a/frontend":{"expose":["own.example.com"]},"frontend":{"expose":["bare.example.com"]}}`,
			want:     map[string]string{"own.example.com": "100.64.0.1:80"},
		},
		{
			name:     "same domain on two services goes to the first key, every time",
			services: `{` + frontend("b", "100.64.0.2", true, "") + `,` + frontend("a", "100.64.0.1", true, "") + `}`,
			routing:  `{"a/frontend":{"expose":["x.example.com"]},"b/frontend":{"expose":["x.example.com"]}}`,
			want:     map[string]string{"x.example.com": "100.64.0.1:80"},
		},
		{
			name:     "old format registry still routes",
			services: liveRegistry,
			routing:  liveRouting,
			want:     map[string]string{"llmapi.example.com": "100.72.41.10:80"},
			wantIDs:  map[string]string{"llmapi.example.com": "llmapi"},
		},
		{
			name:     "migrated registry with old routing keeps the live route and its name",
			services: `{"llmapi/llmapi":{"legacy_key":"llmapi","local_name":"llm","namespace":"llmapi","service":"llmapi","ip":"100.72.41.10","port":80,"public":true}}`,
			routing:  liveRouting,
			want:     map[string]string{"llmapi.example.com": "100.72.41.10:80"},
			wantIDs:  map[string]string{"llmapi.example.com": "llmapi"},
		},
		{
			name:     "renamed legacy key claims its routing entry",
			services: `{"minio-x/minio":{"legacy_key":"minio-x","local_name":"minio-x","namespace":"minio-x","service":"minio","ip":"100.64.0.3","port":9000,"public":true}}`,
			routing:  `{"minio-x":{"expose":["s3.example.com"]}}`,
			want:     map[string]string{"s3.example.com": "100.64.0.3:9000"},
			wantIDs:  map[string]string{"s3.example.com": "minio-x"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Repeat because map iteration order is random and must not matter.
			for i := 0; i < 20; i++ {
				routes := routesFor(t, tt.services, tt.routing)
				got := map[string]string{}
				for _, r := range routes {
					got[r.Domain] = r.Backend
					if strings.Contains(r.Service, "/") {
						t.Errorf("route ID %q contains a slash", r.Service)
					}
					if tt.wantIDs != nil && tt.wantIDs[r.Domain] != r.Service {
						t.Errorf("route ID for %s = %q, want %q", r.Domain, r.Service, tt.wantIDs[r.Domain])
					}
				}
				if len(got) != len(tt.want) {
					t.Fatalf("routes = %v, want %v", got, tt.want)
				}
				for domain, backend := range tt.want {
					if got[domain] != backend {
						t.Errorf("%s -> %q, want %q", domain, got[domain], backend)
					}
				}
			}
		})
	}
}

func TestMigrationLeavesRenderedConfigIdentical(t *testing.T) {
	migrated := `{"llmapi/llmapi":{"legacy_key":"llmapi","local_name":"llm","namespace":"llmapi","service":"llmapi","ip":"100.72.41.10","port":80,"public":true}}`
	s := newTestServer(t, fakeKubectl{})
	before := s.generateTraefikConfig(routesFor(t, liveRegistry, liveRouting))
	after := s.generateTraefikConfig(routesFor(t, migrated, liveRouting))
	a, _ := yaml.Marshal(before)
	b, _ := yaml.Marshal(after)
	if string(a) != string(b) {
		t.Errorf("migration changed the rendered config:\nbefore:\n%s\nafter:\n%s", a, b)
	}
}

func TestRouteRuleWithBlockedPaths(t *testing.T) {
	llmapiBlock := "Host(`llmapi.example.com`) && !PathPrefix(`/admin`) && !PathPrefix(`/docs`) && !PathPrefix(`/redoc`) && !PathPrefix(`/openapi.json`)"
	svc := func(key, service, extra string) string {
		return `{"` + key + `":{"local_name":"x","namespace":"ns","service":"` + service + `","ip":"100.64.0.1","port":80,"public":true` + extra + `}}`
	}
	routing := func(key string) string { return `{"` + key + `":{"expose":["llmapi.example.com"]}}` }

	tests := []struct {
		name     string
		services string
		routing  string
		wantRule string // empty means no route at all
	}{
		{"llmapi old key gets default block", svc("llmapi", "llmapi", ""), routing("llmapi"), llmapiBlock},
		{"llmapi namespaced gets default block", svc("ns/llmapi", "llmapi", ""), routing("ns/llmapi"), llmapiBlock},
		{"explicit empty list turns the block off", svc("ns/llmapi", "llmapi", `,"public_blocked_paths":[]`), routing("ns/llmapi"), "Host(`llmapi.example.com`)"},
		{"explicit list replaces the default", svc("ns/llmapi", "llmapi", `,"public_blocked_paths":["/internal"]`), routing("ns/llmapi"), "Host(`llmapi.example.com`) && !PathPrefix(`/internal`)"},
		{"other services have no default block", svc("ns/app", "app", ""), routing("ns/app"), "Host(`llmapi.example.com`)"},
		{"other services can opt in", svc("ns/app", "app", `,"public_blocked_paths":["/admin"]`), routing("ns/app"), "Host(`llmapi.example.com`) && !PathPrefix(`/admin`)"},
		{"rule injection in a path fails closed", svc("ns/app", "app", ",\"public_blocked_paths\":[\"/x`) || Host(`evil.com\"]"), routing("ns/app"), ""},
		{"non-array field fails closed", svc("ns/app", "app", `,"public_blocked_paths":"/admin"`), routing("ns/app"), ""},
		{"non-string entry fails closed", svc("ns/app", "app", `,"public_blocked_paths":[1]`), routing("ns/app"), ""},
		{"path without leading slash fails closed", svc("ns/app", "app", `,"public_blocked_paths":["admin"]`), routing("ns/app"), ""},
		{"domain injection is skipped", svc("ns/app", "app", ""), "{\"ns/app\":{\"expose\":[\"a.com`) || Host(`evil.com\"]}}", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newTestServer(t, fakeKubectl{})
			routes := routesFor(t, tt.services, tt.routing)
			cfg := s.generateTraefikConfig(routes)

			if tt.wantRule == "" {
				if len(cfg.HTTP.Routers) != 0 {
					t.Fatalf("routers = %v, want none", cfg.HTTP.Routers)
				}
				return
			}
			if len(cfg.HTTP.Routers) != 2 {
				t.Fatalf("got %d routers, want HTTPS and HTTP", len(cfg.HTTP.Routers))
			}
			for name, router := range cfg.HTTP.Routers {
				if router.Rule != tt.wantRule {
					t.Errorf("router %s rule = %q, want %q", name, router.Rule, tt.wantRule)
				}
			}
		})
	}
}

func TestDNSEntryValidation(t *testing.T) {
	entry := func(key, name, ip string) string {
		b, _ := json.Marshal(map[string]interface{}{"local_name": name, "ip": ip, "namespace": "n", "service": key})
		return `"` + key + `":` + string(b)
	}
	tests := []struct {
		name  string
		entry string
		want  []DNSEntry
	}{
		{"plain name", entry("a", "chat", "100.64.0.1"), []DNSEntry{{"chat", "100.64.0.1"}}},
		{"dashboard gets the bare domain too", entry("a", "dashboard", "100.64.0.1"), []DNSEntry{{"dashboard", "100.64.0.1"}, {"", "100.64.0.1"}}},
		{"newline injection", entry("a", "x\n1.2.3.4 evil.com", "100.64.0.1"), []DNSEntry{}},
		{"space injection", entry("a", "x evil.com", "100.64.0.1"), []DNSEntry{}},
		{"dotted name", entry("a", "bank.example.com", "100.64.0.1"), []DNSEntry{}},
		{"reserved name", entry("a", "localhost", "100.64.0.1"), []DNSEntry{}},
		{"reserved name, other case", entry("a", "LocalHost", "100.64.0.1"), []DNSEntry{}},
		{"invalid IP", entry("a", "chat", "100.64.0.1 evil.com"), []DNSEntry{}},
		{"command substitution", entry("a", "$(touch /tmp/x)", "100.64.0.1"), []DNSEntry{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newTestServer(t, fakeKubectl{"service-registry": {out: "{" + tt.entry + "}"}})
			got, err := s.getDNSEntries(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if got == nil {
				t.Fatal("entries must never be nil")
			}
			if len(got) != len(tt.want) {
				t.Fatalf("entries = %v, want %v", got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("entry %d = %v, want %v", i, got[i], tt.want[i])
				}
			}
		})
	}
}

func TestDuplicateLocalNameIsDeterministic(t *testing.T) {
	services := `{"b/x":{"local_name":"same","ip":"100.64.0.2"},"a/x":{"local_name":"same","ip":"100.64.0.1"}}`
	for i := 0; i < 20; i++ {
		s := newTestServer(t, fakeKubectl{"service-registry": {out: services}})
		got, err := s.getDNSEntries(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 || got[0].IP != "100.64.0.1" {
			t.Fatalf("got %v", got)
		}
	}
}

func TestAuthMiddleware(t *testing.T) {
	tests := []struct {
		name       string
		remote     string
		token      string
		configured string
		want       int
	}{
		{"tailnet IPv4 with token", "100.64.1.2:1000", "secret", "secret", 200},
		{"tailnet IPv6 with token", "[fd7a:115c:a1e0::1]:1000", "secret", "secret", 200},
		{"loopback with token", "127.0.0.1:1000", "secret", "secret", 200},
		{"tailnet with wrong token", "100.64.1.2:1000", "wrong", "secret", 401},
		{"tailnet with no token", "100.64.1.2:1000", "", "secret", 401},
		{"public 100.x address", "100.1.2.3:1000", "secret", "secret", 403},
		{"public 100.128 address", "100.128.0.1:1000", "secret", "secret", 403},
		{"public address", "8.8.8.8:1000", "secret", "secret", 403},
		{"LAN address", "192.168.1.5:1000", "secret", "secret", 403},
		{"unparsable address", "garbage", "secret", "secret", 403},
		{"no token configured denies a blank token", "100.64.1.2:1000", "", "", 401},
		{"no token configured denies any token", "100.64.1.2:1000", "x", "", 401},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newTestServer(t, fakeKubectl{})
			s.config.APIToken = tt.configured
			handler := s.authMiddleware(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })

			req := httptest.NewRequest(http.MethodGet, "/api/v1/nodes", nil)
			req.RemoteAddr = tt.remote
			if tt.token != "" {
				req.Header.Set("X-API-Token", tt.token)
			}
			rec := httptest.NewRecorder()
			handler(rec, req)
			if rec.Code != tt.want {
				t.Errorf("status = %d, want %d", rec.Code, tt.want)
			}
		})
	}
}

func heartbeat(s *Server, remote, name, claimedIP string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(HeartbeatRequest{NodeName: name, NodeType: "laptop", NodeIP: claimedIP, ConfigVersion: "v1"})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/heartbeat", strings.NewReader(string(body)))
	req.RemoteAddr = remote
	rec := httptest.NewRecorder()
	s.handleHeartbeat(rec, req)
	return rec
}

func TestHeartbeatSpoofing(t *testing.T) {
	s := newTestServer(t, fakeKubectl{})

	if rec := heartbeat(s, "100.64.0.1:5", "node-a", "9.9.9.9"); rec.Code != 200 {
		t.Fatalf("first heartbeat: %d", rec.Code)
	}
	if got := s.nodes["node-a"].IP; got != "100.64.0.1" {
		t.Errorf("recorded IP = %s, want the observed address", got)
	}

	if rec := heartbeat(s, "100.64.0.2:5", "node-a", "100.64.0.1"); rec.Code != http.StatusConflict {
		t.Errorf("takeover of an online node: status = %d, want 409", rec.Code)
	}
	if got := s.nodes["node-a"].IP; got != "100.64.0.1" {
		t.Errorf("takeover changed the IP to %s", got)
	}

	if rec := heartbeat(s, "100.64.0.1:6", "node-a", ""); rec.Code != 200 {
		t.Errorf("the real node must keep working: %d", rec.Code)
	}

	// A node that moved address is accepted once its old record is not online.
	s.nodes["node-a"].LastHeartbeat = time.Now().Add(-time.Hour)
	if rec := heartbeat(s, "100.64.0.9:5", "node-a", ""); rec.Code != 200 {
		t.Errorf("re-addressed node: status = %d, want 200", rec.Code)
	}

	// Records written by an older server can hold "unknown".
	s.nodes["node-b"] = &Node{Name: "node-b", IP: "unknown", LastHeartbeat: time.Now()}
	if rec := heartbeat(s, "100.64.0.3:5", "node-b", ""); rec.Code != 200 {
		t.Errorf("unknown IP must not conflict: %d", rec.Code)
	}

	// Loopback is the control plane itself: the claim is more useful than 127.0.0.1.
	if rec := heartbeat(s, "127.0.0.1:5", "node-c", "100.64.0.4"); rec.Code != 200 {
		t.Fatalf("loopback heartbeat: %d", rec.Code)
	}
	if got := s.nodes["node-c"].IP; got != "100.64.0.4" {
		t.Errorf("loopback recorded IP = %s", got)
	}
}

func TestHeartbeatRejectsBadInput(t *testing.T) {
	tests := []struct {
		name string
		body string
		want int
	}{
		{"oversized body", `{"node_name":"` + strings.Repeat("a", maxHeartbeatBytes+1) + `","node_type":"laptop"}`, http.StatusRequestEntityTooLarge},
		{"invalid JSON", `{`, 400},
		{"missing name", `{"node_type":"laptop"}`, 400},
		{"name with a slash", `{"node_name":"a/b","node_type":"laptop"}`, 400},
		{"name with a newline", "{\"node_name\":\"a\\nb\",\"node_type\":\"laptop\"}", 400},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newTestServer(t, fakeKubectl{})
			req := httptest.NewRequest(http.MethodPost, "/api/v1/heartbeat", strings.NewReader(tt.body))
			req.RemoteAddr = "100.64.0.1:5"
			rec := httptest.NewRecorder()
			s.handleHeartbeat(rec, req)
			if rec.Code != tt.want {
				t.Errorf("status = %d, want %d", rec.Code, tt.want)
			}
		})
	}
}

func TestNodeDeleteRestrictions(t *testing.T) {
	localAddr := &net.TCPAddr{IP: net.ParseIP("100.64.0.100"), Port: 8443}
	tests := []struct {
		name   string
		remote string
		want   int
	}{
		{"loopback", "127.0.0.1:5", 200},
		{"control plane through its own Tailscale IP", "100.64.0.100:5", 200},
		{"the node itself", "100.64.0.1:5", 200},
		{"another token holder", "100.64.0.2:5", 403},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newTestServer(t, fakeKubectl{})
			s.nodes["victim"] = &Node{Name: "victim", IP: "100.64.0.1"}

			req := httptest.NewRequest(http.MethodDelete, "/api/v1/nodes/victim", nil)
			req.RemoteAddr = tt.remote
			req = req.WithContext(context.WithValue(req.Context(), http.LocalAddrContextKey, net.Addr(localAddr)))
			rec := httptest.NewRecorder()
			s.handleNodeDelete(rec, req)

			if rec.Code != tt.want {
				t.Fatalf("status = %d, want %d", rec.Code, tt.want)
			}
			_, stillThere := s.nodes["victim"]
			if stillThere != (tt.want != 200) {
				t.Errorf("node present = %v after status %d", stillThere, rec.Code)
			}
		})
	}
}

func TestSaveNodesIsAtomicAndPrivate(t *testing.T) {
	s := newTestServer(t, fakeKubectl{})
	s.nodes["a"] = &Node{Name: "a", IP: "100.64.0.1"}
	s.saveNodes()

	info, err := os.Stat(s.nodesFile)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Errorf("mode = %v, want 0600", info.Mode().Perm())
	}
	entries, _ := os.ReadDir(filepath.Dir(s.nodesFile))
	if len(entries) != 1 {
		t.Errorf("temp files left behind: %v", entries)
	}

	s.nodes = make(map[string]*Node)
	s.loadNodes()
	if s.nodes["a"] == nil {
		t.Error("saved node did not load back")
	}
}

func TestLoadNodesIgnoresNull(t *testing.T) {
	s := newTestServer(t, fakeKubectl{})
	if err := os.WriteFile(s.nodesFile, []byte("null"), 0600); err != nil {
		t.Fatal(err)
	}
	s.loadNodes()
	if s.nodes == nil {
		t.Fatal("a null registry file must not leave a nil map")
	}
}

func TestHealthAdvertisesRegistrySchema(t *testing.T) {
	s := newTestServer(t, fakeKubectl{})
	rec := httptest.NewRecorder()
	s.handleHealth(rec, httptest.NewRequest(http.MethodGet, "/api/v1/health", nil))
	var body map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["registry_schema"] != float64(registrySchemaVersion) {
		t.Errorf("registry_schema = %v", body["registry_schema"])
	}
}
