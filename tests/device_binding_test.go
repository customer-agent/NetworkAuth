package tests

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	public "NetworkAuth/controllers/public"
	"NetworkAuth/database"
	"NetworkAuth/models"
	"NetworkAuth/services"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

const (
	deviceAppUUID   = "APP-DEVICE-1"
	deviceAppSecret = "test-app-secret"
	deviceUsername  = "alice"
	devicePassword  = "correct horse battery staple"
)

// Each test uses a real SQLite database and the production login service.
// Tests are deliberately sequential: NetworkAuth stores its DB in a process
// singleton. The connection limit matches database.initSQLite in production.
func newDeviceBindingDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "device.db")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	sqlDB.SetMaxOpenConns(1)
	sqlDB.SetMaxIdleConns(1)
	if err := db.AutoMigrate(&models.App{}, &models.Member{}, &models.Binding{}, &models.MemberSession{}, &models.MemberLevel{}, &models.Blacklist{}, &models.MemberLog{}, &models.API{}); err != nil {
		t.Fatalf("automigrate: %v", err)
	}
	app := models.App{
		UUID: deviceAppUUID, Name: "device-binding-test", Secret: deviceAppSecret,
		Status: 1, OperationMode: models.OperationModeFree,
		MachineVerify: 1, MultiOpenCount: 1, LoginType: models.LoginTypeReject,
		CheckInterval: 10, OfflineTimeout: 30,
	}
	if err := db.Create(&app).Error; err != nil {
		t.Fatalf("create app: %v", err)
	}
	// GORM applies the model's default 2 to a zero-valued scope on Create.
	// Apply the admin setting explicitly, just as the management API does.
	if err := db.Model(&app).Update("multi_open_scope", models.MultiOpenScopeMachine).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.API{AppUUID: deviceAppUUID, APIType: models.APITypeUserLogin, Status: 1}).Error; err != nil {
		t.Fatal(err)
	}
	database.SetDB(db)
	t.Cleanup(func() {
		database.SetDB(nil)
		_ = sqlDB.Close()
	})
	if _, err := services.CreateMember(deviceAppUUID, deviceUsername, devicePassword, models.CardDurationPermanent, 0, "deployment test"); err != nil {
		t.Fatalf("create member: %v", err)
	}
	return db
}

func deviceLogin(machine string) (*services.LoginResult, error) {
	return services.AccountLogin(deviceAppUUID, deviceUsername, devicePassword, machine, "192.0.2.10", "1.0.0", "test device")
}

func assertDeviceState(t *testing.T, db *gorm.DB, wantBindings, wantSessions int64) {
	t.Helper()
	var bindings, sessions int64
	if err := db.Model(&models.Binding{}).Where("type = ?", models.BindingTypeMachine).Count(&bindings).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&models.MemberSession{}).Count(&sessions).Error; err != nil {
		t.Fatal(err)
	}
	if bindings != wantBindings || sessions != wantSessions {
		t.Fatalf("state: bindings=%d sessions=%d; want %d, %d", bindings, sessions, wantBindings, wantSessions)
	}
}

type deviceAPIResponse struct {
	Code int    `json:"code"`
	Msg  string `json:"msg"`
	Data string `json:"data"`
}

func signedDeviceLogin(t *testing.T, appUUID, secret string, params map[string]any) deviceAPIResponse {
	t.Helper()
	data, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Now().Unix()
	body, err := json.Marshal(map[string]any{
		"app_uuid": appUUID, "api_type": models.APITypeUserLogin, "data": string(data), "timestamp": ts,
		"sign": services.SignOpenRequest(appUUID, models.APITypeUserLogin, string(data), ts, secret),
	})
	if err != nil {
		t.Fatal(err)
	}
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.POST("/api/open", public.OpenAPIHandler)
	req := httptest.NewRequest(http.MethodPost, "/api/open", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.RemoteAddr = "192.0.2.10:1234"
	rsp := httptest.NewRecorder()
	router.ServeHTTP(rsp, req)
	if rsp.Code != http.StatusOK {
		t.Fatalf("HTTP %d: %s", rsp.Code, rsp.Body.String())
	}
	var result deviceAPIResponse
	if err := json.Unmarshal(rsp.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func loginParams(machine any) map[string]any {
	params := map[string]any{"username": deviceUsername, "password": devicePassword, "version": "1.0.0"}
	if machine != nil {
		params["machine_code"] = machine
	}
	return params
}

func TestDeploymentDeviceBindingMissingEmptyAndWhitespaceRejected(t *testing.T) {
	db := newDeviceBindingDB(t)
	for _, tc := range []struct {
		name    string
		machine any
	}{
		{"missing", nil}, {"empty", ""}, {"whitespace", " \t\n\u3000"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rsp := signedDeviceLogin(t, deviceAppUUID, deviceAppSecret, loginParams(tc.machine))
			if rsp.Code == 0 || !strings.Contains(rsp.Msg, "机器码") {
				t.Fatalf("machine_code %v: expected machine-code error, got %+v", tc.machine, rsp)
			}
			assertDeviceState(t, db, 0, 0)
		})
	}
}

func TestDeploymentDeviceBindingAllCredentialsRequired(t *testing.T) {
	db := newDeviceBindingDB(t)
	for _, tc := range []struct{ name, uuid, secret, username, password string }{
		{"wrong-app", "APP-WRONG", deviceAppSecret, deviceUsername, devicePassword},
		{"wrong-secret", deviceAppUUID, "wrong-secret", deviceUsername, devicePassword},
		{"wrong-username", deviceAppUUID, deviceAppSecret, "mallory", devicePassword},
		{"wrong-password", deviceAppUUID, deviceAppSecret, deviceUsername, "wrong-password"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			params := loginParams("machine-a")
			params["username"], params["password"] = tc.username, tc.password
			if rsp := signedDeviceLogin(t, tc.uuid, tc.secret, params); rsp.Code == 0 {
				t.Fatalf("invalid credentials accepted: %+v", rsp)
			}
			assertDeviceState(t, db, 0, 0)
		})
	}
	rsp := signedDeviceLogin(t, deviceAppUUID, deviceAppSecret, loginParams("machine-a"))
	if rsp.Code != 0 {
		t.Fatalf("valid credentials rejected: %+v", rsp)
	}
	var result services.LoginResult
	if err := json.Unmarshal([]byte(rsp.Data), &result); err != nil || result.Token == "" {
		t.Fatalf("valid login has no token: err=%v data=%s", err, rsp.Data)
	}
	assertDeviceState(t, db, 1, 1)
}

func TestDeploymentDeviceBindingFirstMachineThenSecondRejected(t *testing.T) {
	db := newDeviceBindingDB(t)
	first, err := deviceLogin("machine-a")
	if err != nil || first == nil || first.Token == "" {
		t.Fatalf("first login: result=%+v err=%v", first, err)
	}
	assertDeviceState(t, db, 1, 1)

	// A shared public IP must not make a different device count as this one.
	if _, err := deviceLogin("machine-b"); err == nil || !strings.Contains(err.Error(), "机器码未绑定") {
		t.Fatalf("second machine should be rejected by binding, got %v", err)
	}
	assertDeviceState(t, db, 1, 1)
	if _, err := services.CheckMemberStatus(deviceAppUUID, first.Token, true); err != nil {
		t.Fatalf("rejected login disrupted existing session: %v", err)
	}

	// Relogin on the bound device replaces its session, rather than consuming
	// an additional device slot.
	again, err := deviceLogin("machine-a")
	if err != nil || again.Token == "" || again.Token == first.Token {
		t.Fatalf("bound device relogin: result=%+v err=%v", again, err)
	}
	assertDeviceState(t, db, 1, 1)
	if _, err := services.CheckMemberStatus(deviceAppUUID, first.Token, true); err == nil {
		t.Fatal("old session still valid after same-device relogin")
	}
	if err := services.MemberLogout(deviceAppUUID, again.Token); err != nil {
		t.Fatal(err)
	}
	assertDeviceState(t, db, 1, 0)
	// This is permanent device binding, not merely a simultaneous-session cap.
	if _, err := deviceLogin("machine-b"); err == nil || !strings.Contains(err.Error(), "机器码未绑定") {
		t.Fatalf("second machine accepted after logout: %v", err)
	}
	assertDeviceState(t, db, 1, 0)
}

func TestDeploymentDeviceBindingConcurrentFirstLogin(t *testing.T) {
	db := newDeviceBindingDB(t)
	const attempts = 8
	type outcome struct {
		machine string
		result  *services.LoginResult
		err     error
	}
	outcomes := make(chan outcome, attempts)
	start := make(chan struct{})
	var ready sync.WaitGroup
	ready.Add(attempts)
	for i := 0; i < attempts; i++ {
		go func(i int) {
			machine := fmt.Sprintf("machine-%d", i)
			ready.Done()
			<-start
			result, err := deviceLogin(machine)
			outcomes <- outcome{machine, result, err}
		}(i)
	}
	ready.Wait()
	close(start)
	var winner string
	for i := 0; i < attempts; i++ {
		outcome := <-outcomes
		if outcome.err == nil {
			if winner != "" {
				t.Fatalf("multiple devices logged in: %s and %s", winner, outcome.machine)
			}
			if outcome.result == nil || outcome.result.Token == "" {
				t.Fatal("successful login returned no token")
			}
			winner = outcome.machine
		} else if !strings.Contains(outcome.err.Error(), "机器码未绑定") {
			t.Fatalf("concurrent login failed for unexpected reason: %v", outcome.err)
		}
	}
	if winner == "" {
		t.Fatal("no concurrent login succeeded")
	}
	assertDeviceState(t, db, 1, 1)
	var binding models.Binding
	if err := db.Where("type = ?", models.BindingTypeMachine).First(&binding).Error; err != nil {
		t.Fatal(err)
	}
	if binding.Value != winner {
		t.Fatalf("binding=%q, winning device=%q", binding.Value, winner)
	}
}
