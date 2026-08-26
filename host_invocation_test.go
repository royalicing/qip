package main

import "testing"

func TestParseHostedInvocation(t *testing.T) {
	hosts, args, err := parseHostedInvocation([]string{"QIP.Dev", "mirror.example:443", "run", "text/component.wasm"})
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) != 2 || hosts[0].Authority != "qip.dev" || hosts[1].Authority != "mirror.example:443" {
		t.Fatalf("hosts=%#v", hosts)
	}
	if len(args) != 2 || args[0] != "run" || args[1] != "text/component.wasm" {
		t.Fatalf("args=%#v", args)
	}
}

func TestParseHostedInvocationLeavesOrdinaryCommandsAlone(t *testing.T) {
	hosts, args, err := parseHostedInvocation([]string{"router", "dev", "site"})
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) != 0 || len(args) != 3 || args[0] != "router" {
		t.Fatalf("hosts=%#v args=%#v", hosts, args)
	}
}

func TestParseHostedInvocationRejectsInvalidHost(t *testing.T) {
	_, _, err := parseHostedInvocation([]string{"https://qip.dev", "run", "component.wasm"})
	if err == nil {
		t.Fatal("expected invalid host error")
	}
}

func TestParseHostedInvocationAcceptsDryRunAlias(t *testing.T) {
	hosts, args, err := parseHostedInvocation([]string{"qip.dev", "dry-run", "component.wasm"})
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) != 1 || len(args) != 2 || args[0] != "dry-run" {
		t.Fatalf("hosts=%#v args=%#v", hosts, args)
	}
}
