package main

import "testing"

func TestClassifyKindUsesAgentMode(t *testing.T) {
	if got := classifyKind("用一句话回答：1+1 等于几", "agent"); got != "agent" {
		t.Fatalf("classifyKind() = %q, want agent", got)
	}
}

func TestClassifyKindKeepsSpecificCommandKinds(t *testing.T) {
	if got := classifyKind("整理未读邮件", ""); got != "email" {
		t.Fatalf("classifyKind(email) = %q, want email", got)
	}
	if got := classifyKind("修复这个 bug", ""); got != "code" {
		t.Fatalf("classifyKind(code) = %q, want code", got)
	}
}
