package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRoutedSplitTunnel(t *testing.T) {
	if !otherTunnel(networkSnapshot{TestRoute: []string{"interface: en0"}, GatewayAndTunnelRoutes: [][]string{{"10/8", "link#22", "UCS", "utun4"}}}) {
		t.Fatal("accepted an existing split tunnel")
	}
}
func TestAcceptanceCopiesOnlyPortableProfiles(t *testing.T) {
	root := t.TempDir()
	original := filepath.Join(root, "source", "guiConfigs")
	copyDir := filepath.Join(root, "temporary")
	check(os.MkdirAll(filepath.Join(original, "profiles"), 0700))
	check(os.Mkdir(copyDir, 0700))
	check(os.WriteFile(filepath.Join(original, "profiles/node.yaml"), []byte("{}"), 0600))
	check(os.WriteFile(filepath.Join(root, "outside"), []byte("private"), 0600))
	check(os.Symlink(filepath.Join(root, "outside"), filepath.Join(original, "link")))
	for _, name := range []string{"webapi-auth.json", "native-pending-edit.json"} {
		check(os.WriteFile(filepath.Join(original, name), []byte("{}"), 0600))
	}
	settings := obj{"IndexId": "selected", "TunModeItem": obj{"EnableTun": true}, "Inbound": []obj{{"LocalPort": 3}}}
	file := filepath.Join(original, "guiNConfig.json")
	writeJSON(file, settings)
	prior := readFile(file)
	db := filepath.Join(original, "guiNDB.db")
	sql(db, "CREATE TABLE ProfileItem(Address TEXT, ConfigType INTEGER)")
	for _, address := range []string{"profiles/node.yaml", filepath.Join(original, "profiles/node.yaml"), "missing.json", "link"} {
		sql(db, "INSERT INTO ProfileItem VALUES("+quoteSQL(address)+",2)")
	}
	staged := copyAcceptanceConfig(filepath.Dir(original), copyDir)
	if staged["TunModeItem"].(obj)["EnableTun"] != false || readFile(file) != prior {
		t.Fatal("copy changed original or enabled TUN")
	}
	out := filepath.Join(copyDir, "guiConfigs")
	names := strings.Fields(sql(filepath.Join(out, "guiNDB.db"), "SELECT Address FROM ProfileItem ORDER BY rowid"))
	if len(names) != 4 {
		t.Fatal(names)
	}
	for i, name := range names {
		data, e := os.ReadFile(filepath.Join(out, name))
		if i < 2 && (e != nil || string(data) != "{}") || i >= 2 && !os.IsNotExist(e) {
			t.Fatal(name, e)
		}
	}
	for _, name := range []string{"webapi-auth.json", "native-pending-edit.json"} {
		if _, e := os.Stat(filepath.Join(out, name)); !os.IsNotExist(e) {
			t.Fatal("unexpected private file", name)
		}
	}
}

func TestReviewedXrayVersionAndMarkerMustMatchWholeFields(t *testing.T) {
	pin := xrayPin{Version: "1.2.3", BuildMarker: "fixture-bind2"}
	if !pin.matches("Xray 1.2.3 (Xray) fixture-bind2 (go1.23 darwin/arm64)") {
		t.Fatal("rejected pinned build")
	}
	for _, version := range []string{"", "Xray 1.2.4 fixture-bind2", "Xray 1.2.3 fixture-bind20", "other 1.2.3 fixture-bind2"} {
		if pin.matches(version) {
			t.Errorf("accepted %q", version)
		}
	}
}
