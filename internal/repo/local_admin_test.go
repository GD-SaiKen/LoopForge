package repo

import (
	"errors"
	"testing"

	"agentflow/internal/domain"
)

func TestBootstrapAdminIsIdempotent(t *testing.T) {
	s, err := OpenTest()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	u, err := s.BootstrapLocalAdmin("fixture-initial-password")
	if err != nil {
		t.Fatal(err)
	}
	if !domain.IsPlatformAdmin(u) || !s.CheckLocalPassword(u.ID, "fixture-initial-password") {
		t.Fatal("administrator missing")
	}
	again, err := s.BootstrapLocalAdmin("fixture-replacement-password")
	if err != nil {
		t.Fatal(err)
	}
	if again.ID != u.ID || !s.CheckLocalPassword(u.ID, "fixture-initial-password") || s.CheckLocalPassword(u.ID, "fixture-replacement-password") {
		t.Fatal("bootstrap replaced existing credentials")
	}
}

func TestBootstrapAdminRejectsExistingIdentity(t *testing.T) {
	s, err := OpenTest()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.PutUser(domain.User{LoginName: "admin"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.BootstrapLocalAdmin("fixture-initial-password"); !errors.Is(err, ErrLoginTaken) {
		t.Fatalf("wanted identity conflict, got %v", err)
	}
	if s.IsPlatformAdmin("admin") {
		t.Fatal("existing user was promoted")
	}
}
