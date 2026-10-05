package main

/*
#include <stdlib.h>
#cgo LDFLAGS: -lnet_connection
#include <network/netmanager/net_connection.h>
static int physical_network(void) {
 NetConn_NetHandleList list = {0};
 if (OH_NetConn_GetAllNets(&list) != 0) return -1;
 for (int preferred = NETCONN_BEARER_WIFI; preferred >= NETCONN_BEARER_CELLULAR; --preferred) {
  for (int i = 0; i < list.netHandleListSize && i < NETCONN_MAX_NET_SIZE; ++i) {
   NetConn_NetCapabilities caps = {0};
   if (OH_NetConn_GetNetCapabilities(&list.netHandles[i], &caps) != 0) continue;
   int physical = 0, vpn = 0, internet = 0, validated = 0;
   for (int j = 0; j < caps.bearerTypesSize && j < NETCONN_MAX_BEARER_TYPE_SIZE; ++j) {
    physical |= caps.bearerTypes[j] == preferred;
    vpn |= caps.bearerTypes[j] == NETCONN_BEARER_VPN;
   }
   for (int j = 0; j < caps.netCapsSize && j < NETCONN_MAX_CAP_SIZE; ++j) {
    internet |= caps.netCaps[j] == NETCONN_NET_CAPABILITY_INTERNET;
    validated |= caps.netCaps[j] == NETCONN_NET_CAPABILITY_VALIDATED;
   }
   if (physical && !vpn && internet && validated) return list.netHandles[i].netId;
  }
 }
 return -1;
}
static int bind_physical(int fd, int net_id) {
 NetConn_NetHandle handle = {net_id};
 return OH_NetConn_BindSocket(fd, &handle);
}
*/
import "C"

import (
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/dlclark/regexp2"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	M "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener/sing_tun"
	clashlog "github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	logger "github.com/sirupsen/logrus"
	"io"
)

type startOptions struct {
	Home       string            `json:"home"`
	ConfigPath string            `json:"configPath"`
	Mode       string            `json:"mode"`
	Port       int               `json:"port"`
	Secret     string            `json:"secret"`
	Selections map[string]string `json:"selections"`
}
type nodeInfo struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Delay int    `json:"delay"`
}
type proxyGroup struct {
	Name string   `json:"name"`
	Type string   `json:"type"`
	All  []string `json:"all"`
	Now  string   `json:"now"`
}
type inspectResult struct {
	Groups        []proxyGroup `json:"groups"`
	Nodes         []nodeInfo   `json:"nodes"`
	DynamicGroups []string     `json:"dynamicGroups"`
}

var trustOnce sync.Once
var trustError error

func initializeTrust(home string) error {
	trustOnce.Do(func() {
		pem, err := os.ReadFile(filepath.Join(home, "cacert.pem"))
		if err != nil {
			trustError = fmt.Errorf("read native CA bundle: %w", err)
			return
		}
		roots := x509.NewCertPool()
		if !roots.AppendCertsFromPEM(pem) {
			trustError = errors.New("native CA bundle contains no valid certificates")
			return
		}
		settings := strings.Split(os.Getenv("GODEBUG"), ",")
		filtered := settings[:0]
		for _, setting := range settings {
			if !strings.HasPrefix(setting, "x509usefallbackroots=") {
				filtered = append(filtered, setting)
			}
		}
		filtered = append(filtered, "x509usefallbackroots=1")
		if err := os.Setenv("GODEBUG", strings.Join(filtered, ",")); err != nil {
			trustError = fmt.Errorf("configure native CA bundle: %w", err)
			return
		}
		x509.SetFallbackRoots(roots)
	})
	return trustError
}

var mu sync.Mutex
var active bool
var coreTun *sing_tun.Listener
var selectedNetwork atomic.Int32
var activePort int
var activeSecret string

func cstring(value string) *C.char { return C.CString(value) }
func validateGroupFilters(raw *config.RawConfig) error {
	for _, group := range raw.ProxyGroup {
		for _, key := range [...]string{"filter", "exclude-filter"} {
			value, ok := group[key].(string)
			if !ok || value == "" {
				continue
			}
			for _, expression := range strings.Split(value, "`") {
				if _, err := regexp2.Compile(expression, regexp2.None); err != nil {
					return fmt.Errorf("Invalid proxy-group %s", key)
				}
			}
		}
	}
	return nil
}

//export FlClashInspect
func FlClashInspect(configText *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	raw, err := config.UnmarshalRawConfig([]byte(C.GoString(configText)))
	if err != nil {
		return cstring("ERROR:invalid configuration")
	}
	if err = validateGroupFilters(raw); err != nil {
		return cstring("ERROR:" + err.Error())
	}
	result := inspectResult{Groups: make([]proxyGroup, 0, len(raw.ProxyGroup)), Nodes: make([]nodeInfo, 0, len(raw.Proxy)), DynamicGroups: make([]string, 0)}
	for _, item := range raw.Proxy {
		name, nameOK := item["name"].(string)
		typ, typeOK := item["type"].(string)
		if !nameOK || name == "" || !typeOK || typ == "" {
			return cstring("ERROR:invalid configuration")
		}
		result.Nodes = append(result.Nodes, nodeInfo{Name: name, Type: typ, Delay: -1})
	}
	for _, item := range raw.ProxyGroup {
		name, nameOK := item["name"].(string)
		typ, typeOK := item["type"].(string)
		if typ == "select" {
			typ = "Selector"
		}
		if !nameOK || name == "" || !typeOK || typ == "" {
			return cstring("ERROR:invalid configuration")
		}
		dynamic := item["include-all"] == true || item["include-all-providers"] == true || item["include-all-proxies"] == true
		switch uses := item["use"].(type) {
		case []any:
			dynamic = dynamic || len(uses) > 0
		case []string:
			dynamic = dynamic || len(uses) > 0
		}
		if dynamic {
			result.DynamicGroups = append(result.DynamicGroups, name)
		}
		members := make([]string, 0)
		switch values := item["proxies"].(type) {
		case []any:
			for _, value := range values {
				if s, ok := value.(string); ok {
					members = append(members, s)
				}
			}
		case []string:
			members = append(members, values...)
		}
		current := ""
		current, _ = item["default-selected"].(string)
		if current == "" {
			current, _ = item["now"].(string)
		}
		if current == "" && len(members) > 0 {
			current = members[0]
		}
		result.Groups = append(result.Groups, proxyGroup{Name: name, Type: typ, All: members, Now: current})
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return cstring("ERROR:could not serialize configuration")
	}
	return cstring(string(encoded))
}

//export FlClashStart
func FlClashStart(optionsJSON *C.char, descriptor C.int) (result *C.char) {
	defer func() {
		if recover() != nil {
			result = cstring("Mihomo rejected the configuration during startup")
		}
	}()
	var options startOptions
	if err := json.Unmarshal([]byte(C.GoString(optionsJSON)), &options); err != nil {
		return cstring("Invalid core startup options")
	}
	if options.Home == "" || options.ConfigPath == "" || options.Secret == "" || options.Port != 9097 {
		return cstring("Incomplete core startup options")
	}
	mode, ok := tunnel.ModeMapping[strings.ToLower(options.Mode)]
	if !ok {
		return cstring("Invalid proxy mode")
	}
	mu.Lock()
	defer mu.Unlock()
	if active {
		return cstring("Core is already running")
	}
	if err := os.MkdirAll(options.Home, 0700); err != nil {
		return cstring("Unable to prepare core home")
	}
	M.SetHomeDir(options.Home)
	configPath := options.ConfigPath
	if !filepath.IsAbs(configPath) {
		configPath = filepath.Join(options.Home, configPath)
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		return cstring("Unable to read selected configuration")
	}
	if err := initializeTrust(options.Home); err != nil {
		return cstring(err.Error())
	}
	raw, err := config.UnmarshalRawConfig(data)
	if err != nil {
		return cstring("Invalid mihomo configuration")
	}
	if err = validateGroupFilters(raw); err != nil {
		return cstring(err.Error())
	}
	raw.Mode = mode
	raw.Profile.StoreSelected = false
	raw.Port, raw.SocksPort, raw.MixedPort, raw.RedirPort, raw.TProxyPort = 0, 0, 0, 0, 0
	raw.AllowLan = false
	raw.BindAddress = "127.0.0.1"
	raw.Listeners = nil
	raw.TuicServer.Enable = false
	raw.ShadowSocksConfig = ""
	raw.VmessConfig = ""
	raw.Authentication = nil
	raw.Tunnels = nil
	raw.ExternalController = fmt.Sprintf("127.0.0.1:%d", options.Port)
	raw.ExternalControllerTLS, raw.ExternalControllerUnix, raw.ExternalControllerPipe = "", "", ""
	raw.ExternalControllerCors = config.RawCors{AllowOrigins: []string{}, AllowPrivateNetwork: false}
	raw.ExternalControllerRoutingMark = 0
	raw.ExternalDohServer = ""
	raw.ExternalUI, raw.ExternalUIURL, raw.ExternalUIName = "", "", ""
	raw.Secret = options.Secret
	// The OS VPN directs DNS to its private TUN address. Preserve the profile's
	// upstreams, policies and enhanced mode, but always serve that internal DNS
	// endpoint without exposing a public DNS listener.
	raw.DNS.Enable = true
	raw.DNS.Listen = ""
	raw.Tun.Enable = true
	raw.Tun.Stack = M.TunGvisor
	raw.Tun.FileDescriptor = int(descriptor)
	raw.Tun.MTU = 1400
	raw.Tun.AutoRoute = false
	raw.Tun.AutoRedirect = false
	raw.IPTables.Enable = false
	raw.Tun.AutoDetectInterface = false
	raw.Tun.DNSHijack = []string{"any:53"}
	physical := C.physical_network()
	if physical < 0 {
		return cstring("No validated non-VPN Wi-Fi or cellular network")
	}
	selectedNetwork.Store(int32(physical))
	dialer.DefaultSocketHook = func(_ string, _ string, conn syscall.RawConn) error {
		netID := selectedNetwork.Load()
		if netID < 0 {
			return errors.New("no validated non-VPN network is available")
		}
		var result C.int
		if err := conn.Control(func(socket uintptr) { result = C.bind_physical(C.int(socket), C.int(netID)) }); err != nil {
			return err
		}
		if result != 0 {
			return fmt.Errorf("OH_NetConn_BindSocket failed: %d", int(result))
		}
		return nil
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		return cstring("Invalid mihomo configuration")
	}
	cfg.General.Tun.MTU = 1400
	cfg.General.Tun.Inet4Address = []netip.Prefix{netip.MustParsePrefix("172.19.0.1/30")}
	cfg.General.Tun.Inet6Address = []netip.Prefix{netip.MustParsePrefix("fdfe:dcba:9876::1/126")}
	// Preserve user rules, providers, DNS upstreams/policies and geodata.
	// The VPN-owned TUN/internal DNS, OS routing hooks, public listeners and
	// authenticated loopback controller are the platform-specific overrides.
	cfg.General.Tun.Enable = false
	logger.SetOutput(io.Discard)
	committed := false
	defer func() {
		if !committed {
			selectedNetwork.Store(-1)
			stopController(options.Port, options.Secret)
		}
	}()
	hub.ApplyConfig(cfg)
	// Providers must be populated before validating their member names. App-owned
	// per-profile choices take precedence over Mihomo's shared group-name cache.
	if globalProxy, exists := cfg.Proxies["GLOBAL"]; exists {
		if global, selectable := globalProxy.Adapter().(*outboundgroup.Selector); selectable {
			explicit := false
			choice := ""
			for _, group := range raw.ProxyGroup {
				if group["name"] == "GLOBAL" {
					explicit = true
					break
				}
			}
			if !explicit {
				for _, group := range raw.ProxyGroup {
					if name, ok := group["name"].(string); ok && name != "" && name != "GLOBAL" {
						choice = name
						break
					}
				}
				if choice == "" {
					for _, node := range raw.Proxy {
						if name, ok := node["name"].(string); ok && name != "" {
							choice = name
							break
						}
					}
				}
				if choice == "" && options.Mode == "global" {
					return cstring("No proxy is available for global mode")
				}
			}
			if choice != "" {
				if err = global.Set(choice); err != nil {
					return cstring("Configured global proxy policy is invalid")
				}
			}
			if saved := options.Selections["GLOBAL"]; saved != "" {
				if err = global.Set(saved); err != nil {
					clashlog.Warnln("Stored GLOBAL selection is no longer available; using configured policy")
				}
			}
		}
	} else {
		return cstring("Mihomo global policy is unavailable")
	}
	for groupName, choice := range options.Selections {
		if groupName == "GLOBAL" {
			continue
		}
		group, exists := cfg.Proxies[groupName]
		if !exists {
			continue
		}
		if selector, selectable := group.Adapter().(*outboundgroup.Selector); selectable && choice != "" {
			if err = selector.Set(choice); err != nil {
				clashlog.Warnln("Stored selection is no longer available for group %s; using configured policy", groupName)
			}
		}
	}
	client := &http.Client{Timeout: 350 * time.Millisecond}
	endpoint := fmt.Sprintf("http://127.0.0.1:%d/version", options.Port)
	ready := false
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest(http.MethodGet, endpoint, nil)
		req.Header.Set("Authorization", "Bearer "+options.Secret)
		response, requestErr := client.Do(req)
		if requestErr == nil {
			if response.StatusCode == http.StatusOK {
				var version struct {
					Version string `json:"version"`
				}
				decodeErr := json.NewDecoder(response.Body).Decode(&version)
				response.Body.Close()
				if decodeErr == nil && version.Version != "" {
					ready = true
					break
				}
			} else {
				unauthorized := response.StatusCode == http.StatusUnauthorized
				response.Body.Close()
				if unauthorized {
					break
				}
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		return cstring("Authenticated mihomo controller did not become ready")
	}
	fd, err := syscall.Dup(int(descriptor))
	if err != nil {
		return cstring("Unable to duplicate VPN descriptor")
	}
	cfg.General.Tun.FileDescriptor = fd
	tun, err := sing_tun.New(cfg.General.Tun, tunnel.Tunnel)
	if err != nil {
		return cstring("Unable to start TUN listener: " + err.Error())
	}
	coreTun = tun
	active = true
	activePort = options.Port
	activeSecret = options.Secret
	committed = true
	return cstring("")
}

//export FlClashStop
func FlClashStop() {
	mu.Lock()
	defer mu.Unlock()
	if !active {
		return
	}
	tunnel.OnSuspend()
	statistic.DefaultManager.Range(func(conn statistic.Tracker) bool {
		_ = conn.Close()
		return true
	})
	if coreTun != nil {
		_ = coreTun.Close()
		coreTun = nil
	}
	stopController(activePort, activeSecret)
	active = false
	activePort = 0
	activeSecret = ""
	selectedNetwork.Store(-1)
}
func stopController(port int, secret string) {
	executor.Shutdown()
	route.ReCreateServer(&route.Config{})
	if port == 0 {
		return
	}
	client := &http.Client{Timeout: 250 * time.Millisecond}
	endpoint := fmt.Sprintf("http://127.0.0.1:%d/version", port)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest(http.MethodGet, endpoint, nil)
		req.Header.Set("Authorization", "Bearer "+secret)
		response, err := client.Do(req)
		if err != nil {
			return
		}
		response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
}

//export FlClashRefreshNetwork
func FlClashRefreshNetwork() {
	netID := int32(C.physical_network())
	if netID < 0 {
		netID = -1
	}
	if selectedNetwork.Swap(netID) != netID {
		// Cached DNS transports must not remain bound to the previous network.
		resolver.ResetConnection()
	}
}

func main() {}
