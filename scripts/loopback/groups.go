package main

import (
	"bufio"
	"bytes"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

func socksRequest(c net.Conn) (string, int, bool) {
	header, e := exact(c, 2)
	if e != nil || header[0] != 5 {
		return "", 0, false
	}
	methods, e := exact(c, int(header[1]))
	if e != nil || !bytes.Contains(methods, []byte{0}) {
		return "", 0, false
	}
	c.Write([]byte{5, 0})
	h, e := exact(c, 4)
	if e != nil || h[0] != 5 || h[1] != 1 {
		return "", 0, false
	}
	var name string
	switch h[3] {
	case 1, 4:
		n := 4
		if h[3] == 4 {
			n = 16
		}
		b, e := exact(c, n)
		if e != nil {
			return "", 0, false
		}
		name = net.IP(b).String()
	case 3:
		s, e := exact(c, 1)
		if e != nil {
			return "", 0, false
		}
		b, e := exact(c, int(s[0]))
		if e != nil {
			return "", 0, false
		}
		name = string(b)
	default:
		return "", 0, false
	}
	b, e := exact(c, 2)
	if e != nil {
		return "", 0, false
	}
	return name, int(be.Uint16(b)), true
}
func activeGroup(root, app, checker string, kind int) {
	dir := filepath.Join(root, fmt.Sprintf("group-%d", kind))
	check(os.Mkdir(dir, 0700))
	var ports []int
	for _, label := range []string{"old", "new", "rejected"} {
		l := tcpListener(func(c net.Conn) {
			name, p, ok := socksRequest(c)
			if !ok {
				return
			}
			if name != "127.0.0.1" || p != 1 {
				c.Write(hexBytes("05020001000000000000"))
				return
			}
			c.Write(hexBytes("05000001000000000000"))
			req, e := http.ReadRequest(bufio.NewReader(c))
			if e != nil || req.Method != "GET" || req.URL.Path != "/marker" {
				return
			}
			fmt.Fprintf(c, "HTTP/1.0 200 OK\r\nContent-Length: %d\r\n\r\n%s", len(label), label)
		})
		defer l.Close()
		ports = append(ports, l.Addr().(*net.TCPAddr).Port)
	}
	inbound := freePort()
	h := startHost([]string{checker, "--serve-group-edit-fixture", app, dir}, nil, nil)
	defer h.close()
	select {
	case line := <-h.lines:
		require(line == "\"ready\"", "invalid group fixture handshake %s", line)
	case <-time.After(12 * time.Second):
		check(fmt.Errorf("group fixture timeout"))
	}
	folder := filepath.Join(dir, "guiConfigs")
	db := filepath.Join(folder, "guiNDB.db")
	query := func(q string) string { return strings.TrimSpace(sql(db, q)) }
	writeJSON(filepath.Join(folder, "broken.json"), obj{"outbounds": []obj{{"protocol": "invalid-fixture-protocol"}}})
	settingsFile := filepath.Join(folder, "guiNConfig.json")
	settings := decode(readFile(settingsFile))
	settings["SpeedTestItem"].(obj)["SpeedPingTestUrl"] = "http://127.0.0.1:2/ping"
	writeJSON(settingsFile, settings)
	template := obj{"log": obj{"loglevel": "none"}, "inbounds": []obj{{"tag": "fixture", "protocol": "http", "listen": "127.0.0.1", "port": inbound}}, "outbounds": []obj{}, "routing": obj{"rules": []obj{{"inboundTag": []string{"fixture"}, "outboundTag": "proxy"}}}}
	query(fmt.Sprintf("INSERT INTO ProfileItem(IndexId,ConfigType,CoreType,ConfigVersion,Remarks,Address) VALUES('broken',2,2,4,'Invalid core fixture','broken.json'); INSERT INTO SubItem(Id,Remarks) VALUES('sub','Subscription fixture'); INSERT INTO ProfileItem(IndexId,ConfigType,CoreType,ConfigVersion,Remarks) VALUES('parent',%d,2,2,'Parent'),('inner',%d,2,2,'Nested'); INSERT INTO ProfileGroupItem(IndexId,ChildItems) VALUES('parent','inner'); INSERT INTO ProfileGroupItem(IndexId,SubChildItems,Filter) VALUES('inner','sub','^Active'); UPDATE FullConfigTemplateItem SET Enabled=1,Config=%s WHERE CoreType=2; CREATE TRIGGER fixture_edit_failure BEFORE UPDATE ON ProfileItem WHEN OLD.IndexId='reserve' AND NEW.Port=%d BEGIN SELECT RAISE(ABORT,'fixture'); END;", 203-kind, kind, quoteSQL(jsonText(template)), ports[2]))
	for _, item := range [][2]string{{"member", "Active one"}, {"reserve", "Reserve"}, {"other", "Other"}} {
		query(fmt.Sprintf("INSERT INTO ProfileItem(IndexId,ConfigType,CoreType,ConfigVersion,Remarks,Address,Port,Subid) VALUES(%s,4,2,4,%s,'127.0.0.1',%d,'sub')", quoteSQL(item[0]), quoteSQL(item[1]), ports[0]))
	}
	current := "parent"
	change := func(action, id string, wantError any, fields obj) string {
		q := obj{"action": action, "id": id}
		for k, v := range fields {
			q[k] = v
		}
		h.send(jsonText(q))
		r := h.receive(12*time.Second, "")
		session, _ := r["session"].(string)
		require(r["error"] == wantError && r["running"] == current && session != "", "%s %s returned %v", action, id, r)
		return session
	}
	edit := func(field string, v any) obj { return obj{"field": field, "value": v} }
	probe := func(label string) {
		body, e := getHTTP("http://127.0.0.1:1/marker", "http://"+endpoint(inbound))
		check(e)
		require(body == label, "got exit %q; want %q", body, label)
	}
	session := change("select", "parent", nil, nil)
	probe("old")
	same := func(id string) { require(id == session, "unrelated or rejected edit restarted session") }
	replaced := func(id string) { require(id != session, "expected new running session"); session = id }
	same(change("edit", "other", nil, edit("port", ports[1])))
	same(change("delete", "other", nil, nil))
	replaced(change("edit", "member", nil, edit("port", ports[1])))
	probe("new")
	same(change("delete", "inner", "profile_in_use_by_group", nil))
	same(change("delete", "member", "profile_group_empty", nil))
	same(change("move", "member", "profile_group_empty", obj{"value": ""}))
	query("INSERT INTO ProfileExItem(IndexId,Delay) VALUES('member',-1)")
	same(change("clean", "member", "profile_group_empty", nil))
	same(change("edit", "member", "profile_group_empty", edit("remarks", "Does not match")))
	require(query("SELECT Remarks FROM ProfileItem WHERE IndexId='member'") == "Active one", "invalid edit persisted")
	probe("new")
	replaced(change("edit", "reserve", nil, edit("remarks", "Active reserve")))
	replaced(change("move", "member", nil, obj{"value": ""}))
	probe("old")
	replaced(change("move", "member", nil, obj{"value": "sub"}))
	action := "delete"
	if kind == 101 {
		action = "clean"
	}
	replaced(change(action, "member", nil, nil))
	require(query("SELECT 1 FROM ProfileItem WHERE IndexId='member'") == "", "member survived")
	probe("old")
	replaced(change("edit", "reserve", "database_operation_failed", edit("port", ports[2])))
	require(query("SELECT Port FROM ProfileItem WHERE IndexId='reserve'") == fmt.Sprint(ports[0]), "failed write changed record")
	probe("old")
	replaced(change("delete", "parent", "core_start_failed", nil))
	require(query("SELECT Remarks FROM ProfileItem WHERE IndexId='parent'") == "Parent", "failed startup deleted parent")
	probe("old")
	feeds := map[string]string{}
	var lock sync.Mutex
	set := func(key, s string) { lock.Lock(); feeds["/"+key] = s; lock.Unlock() }
	feed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lock.Lock()
		body, ok := feeds[r.URL.Path]
		lock.Unlock()
		if !ok {
			http.NotFound(w, r)
			return
		}
		fmt.Fprint(w, body)
	}))
	defer feed.Close()
	query("UPDATE SubItem SET Url=" + quoteSQL(feed.URL+"/sub") + ", Enabled=1 WHERE Id='sub'; UPDATE ProfileItem SET IsSub=1 WHERE IndexId='reserve'")
	for _, key := range []string{"other-sub", "files"} {
		query("INSERT INTO SubItem(Id,Remarks,Url,Enabled) VALUES(" + quoteSQL(key) + "," + quoteSQL(key) + "," + quoteSQL(feed.URL+"/"+key) + ",1)")
	}
	refresh := func(id string) string { return change("refreshSubscription", id, nil, nil) }
	set("other-sub", fmt.Sprintf("socks://127.0.0.1:%d#Unrelated", ports[0]))
	same(refresh("other-sub"))
	require(query("SELECT COUNT(*) FROM ProfileItem WHERE Subid='other-sub'") == "1", "unrelated subscription was not imported")
	update := func(port int) { set("sub", fmt.Sprintf("socks://127.0.0.1:%d#Active%%20reserve", port)) }
	reservePort := func() string { return query("SELECT Port FROM ProfileItem WHERE IndexId='reserve'") }
	update(ports[1])
	replaced(refresh("sub"))
	require(reservePort() == fmt.Sprint(ports[1]), "subscription edit not committed")
	probe("new")
	same(refresh("sub"))
	update(ports[2])
	replaced(refresh("sub"))
	require(reservePort() == fmt.Sprint(ports[1]), "failed subscription edit not rolled back")
	probe("new")
	current = "reserve"
	session = change("select", current, nil, nil)
	update(ports[0])
	replaced(refresh("sub"))
	probe("old")
	fileInbound := obj{"listen": "127.0.0.1", "port": inbound, "protocol": "http"}
	document := obj{"remarks": "File fixture", "inbounds": []obj{fileInbound}, "outbounds": []obj{{"tag": "proxy", "protocol": "socks", "settings": obj{"servers": []obj{{"address": "127.0.0.1", "port": ports[1]}}}}}}
	set("files", jsonText(document))
	refresh("files")
	record := strings.Split(query("SELECT IndexId,Address FROM ProfileItem WHERE Subid='files'"), "|")
	require(len(record) == 2, "missing imported node")
	current = record[0]
	session = change("select", current, nil, nil)
	probe("new")
	fileInbound["port"] = ports[2]
	set("files", jsonText(document))
	replaced(refresh("files"))
	require(query("SELECT Address FROM ProfileItem WHERE IndexId="+quoteSQL(current)) == record[1], "failed file restore")
	names, e := filepath.Glob(filepath.Join(folder, "v2raym-import-*.json"))
	check(e)
	require(len(names) == 1 && filepath.Base(names[0]) == record[1], "orphaned profile file")
	probe("new")
	fmt.Println("PASS active group, subscriptions and rollback", kind)
}
