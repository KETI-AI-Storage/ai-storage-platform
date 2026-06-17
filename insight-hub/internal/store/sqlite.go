package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	_ "modernc.org/sqlite"
)

// Store persists resource snapshots per node (and optionally per pod on that node).
type Store struct {
	db *sql.DB
}

// Open creates or opens SQLite at path (e.g. /data/insight-hub.db).
func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, err
	}
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS resource_snapshots (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	node_name TEXT NOT NULL,
	ts_unix_ms INTEGER NOT NULL,
	cpu_util REAL NOT NULL,
	mem_util REAL NOT NULL,
	gpu_util REAL NOT NULL,
	storage_io_util REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_node_ts ON resource_snapshots(node_name, ts_unix_ms);
CREATE TABLE IF NOT EXISTS orchestration_results (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	policy_name TEXT NOT NULL,
	target_workload TEXT NOT NULL,
	namespace TEXT NOT NULL,
	node TEXT NOT NULL,
	action TEXT NOT NULL,
	result TEXT NOT NULL,
	ts_unix_ms INTEGER NOT NULL,
	before_state_json TEXT,
	after_state_json TEXT,
	metadata_json TEXT
);
CREATE INDEX IF NOT EXISTS idx_orch_result_ts ON orchestration_results(ts_unix_ms);
CREATE INDEX IF NOT EXISTS idx_orch_result_workload ON orchestration_results(namespace, target_workload, ts_unix_ms);
`)
	if err != nil {
		return err
	}
	if err := s.addColumnIfMissing("pod_namespace", "TEXT"); err != nil {
		return err
	}
	if err := s.addColumnIfMissing("pod_name", "TEXT"); err != nil {
		return err
	}
	_, err = s.db.Exec(`CREATE INDEX IF NOT EXISTS idx_node_pod_ts ON resource_snapshots(node_name, pod_namespace, pod_name, ts_unix_ms)`)
	return err
}

// OrchestrationResultIn은 정책 실행 결과 저장 입력 모델이다.
type OrchestrationResultIn struct {
	PolicyName     string
	TargetWorkload string
	Namespace      string
	Node           string
	Action         string
	Result         string
	TsUnixMs       int64
	BeforeState    map[string]interface{}
	AfterState     map[string]interface{}
	Metadata       map[string]interface{}
}

// InsertOrchestrationResult는 정책 실행 결과 1건을 저장한다.
func (s *Store) InsertOrchestrationResult(ctx context.Context, in OrchestrationResultIn) error {
	if in.TsUnixMs == 0 {
		in.TsUnixMs = time.Now().UnixMilli()
	}
	toJSON := func(m map[string]interface{}) (interface{}, error) {
		if len(m) == 0 {
			return nil, nil
		}
		b, err := json.Marshal(m)
		if err != nil {
			return nil, err
		}
		return string(b), nil
	}
	beforeJSON, err := toJSON(in.BeforeState)
	if err != nil {
		return fmt.Errorf("marshal before_state_json: %w", err)
	}
	afterJSON, err := toJSON(in.AfterState)
	if err != nil {
		return fmt.Errorf("marshal after_state_json: %w", err)
	}
	metadataJSON, err := toJSON(in.Metadata)
	if err != nil {
		return fmt.Errorf("marshal metadata_json: %w", err)
	}

	_, err = s.db.ExecContext(ctx,
		`INSERT INTO orchestration_results (
			policy_name, target_workload, namespace, node, action, result, ts_unix_ms,
			before_state_json, after_state_json, metadata_json
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		in.PolicyName,
		in.TargetWorkload,
		in.Namespace,
		in.Node,
		in.Action,
		in.Result,
		in.TsUnixMs,
		beforeJSON,
		afterJSON,
		metadataJSON,
	)
	if err != nil {
		return fmt.Errorf("insert orchestration_results: %w", err)
	}
	return nil
}

func (s *Store) addColumnIfMissing(name, sqlType string) error {
	var n int
	q := fmt.Sprintf(`SELECT COUNT(1) FROM pragma_table_info('resource_snapshots') WHERE name = %q`, name)
	if err := s.db.QueryRow(q).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	_, err := s.db.Exec(fmt.Sprintf(`ALTER TABLE resource_snapshots ADD COLUMN %s %s`, name, sqlType))
	return err
}

// SnapshotIn is one row to insert (PodNs/PodName empty = node-level aggregate).
type SnapshotIn struct {
	TsUnixMs int64
	CPU      float64
	Mem      float64
	GPU      float64
	Sto      float64
	PodNs    string
	PodName  string
}

// InsertSnapshots appends snapshots for a node in one transaction.
func (s *Store) InsertSnapshots(ctx context.Context, node string, rows []SnapshotIn) (int, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx,
		`INSERT INTO resource_snapshots (node_name, ts_unix_ms, cpu_util, mem_util, gpu_util, storage_io_util, pod_namespace, pod_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, err
	}
	defer stmt.Close()

	n := 0
	for i := range rows {
		var pns, pn interface{}
		if rows[i].PodNs != "" && rows[i].PodName != "" {
			pns = rows[i].PodNs
			pn = rows[i].PodName
		}
		if _, err := stmt.ExecContext(ctx, node, rows[i].TsUnixMs, rows[i].CPU, rows[i].Mem, rows[i].GPU, rows[i].Sto, pns, pn); err != nil {
			return n, err
		}
		n++
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return n, nil
}

// SnapshotRow is one stored sample.
type SnapshotRow struct {
	TsUnixMs           int64
	CPU, Mem, GPU, Sto float64
	PodNs              string
	PodName            string
}

// QueryNode returns node-level snapshots only (no pod rows).
func (s *Store) QueryNode(ctx context.Context, node string, sinceUnixMs int64, max int) ([]SnapshotRow, error) {
	if max <= 0 || max > 100000 {
		max = 10000
	}
	nodeOnly := ` AND (pod_namespace IS NULL OR pod_namespace = '') AND (pod_name IS NULL OR pod_name = '')`
	var rows *sql.Rows
	var err error
	if sinceUnixMs > 0 {
		rows, err = s.db.QueryContext(ctx,
			`SELECT ts_unix_ms, cpu_util, mem_util, gpu_util, storage_io_util, IFNULL(pod_namespace,''), IFNULL(pod_name,'') FROM resource_snapshots
			 WHERE node_name = ?`+nodeOnly+` AND ts_unix_ms >= ? ORDER BY ts_unix_ms ASC LIMIT ?`,
			node, sinceUnixMs, max)
	} else {
		rows, err = s.db.QueryContext(ctx,
			`SELECT ts_unix_ms, cpu_util, mem_util, gpu_util, storage_io_util, IFNULL(pod_namespace,''), IFNULL(pod_name,'') FROM resource_snapshots
			 WHERE node_name = ?`+nodeOnly+` ORDER BY ts_unix_ms ASC LIMIT ?`,
			node, max)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []SnapshotRow
	for rows.Next() {
		var r SnapshotRow
		if err := rows.Scan(&r.TsUnixMs, &r.CPU, &r.Mem, &r.GPU, &r.Sto, &r.PodNs, &r.PodName); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// QueryPod returns snapshots for one pod on a node.
func (s *Store) QueryPod(ctx context.Context, node, podNs, podName string, sinceUnixMs int64, max int) ([]SnapshotRow, error) {
	if max <= 0 || max > 100000 {
		max = 10000
	}
	var rows *sql.Rows
	var err error
	if sinceUnixMs > 0 {
		rows, err = s.db.QueryContext(ctx,
			`SELECT ts_unix_ms, cpu_util, mem_util, gpu_util, storage_io_util, IFNULL(pod_namespace,''), IFNULL(pod_name,'') FROM resource_snapshots
			 WHERE node_name = ? AND pod_namespace = ? AND pod_name = ? AND ts_unix_ms >= ? ORDER BY ts_unix_ms ASC LIMIT ?`,
			node, podNs, podName, sinceUnixMs, max)
	} else {
		rows, err = s.db.QueryContext(ctx,
			`SELECT ts_unix_ms, cpu_util, mem_util, gpu_util, storage_io_util, IFNULL(pod_namespace,''), IFNULL(pod_name,'') FROM resource_snapshots
			 WHERE node_name = ? AND pod_namespace = ? AND pod_name = ? ORDER BY ts_unix_ms ASC LIMIT ?`,
			node, podNs, podName, max)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []SnapshotRow
	for rows.Next() {
		var r SnapshotRow
		if err := rows.Scan(&r.TsUnixMs, &r.CPU, &r.Mem, &r.GPU, &r.Sto, &r.PodNs, &r.PodName); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ListNodes returns distinct node names that have node-level data.
func (s *Store) ListNodes(ctx context.Context) ([]string, error) {
	nodeOnly := ` WHERE (pod_namespace IS NULL OR pod_namespace = '') AND (pod_name IS NULL OR pod_name = '')`
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT node_name FROM resource_snapshots`+nodeOnly+` ORDER BY node_name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		names = append(names, n)
	}
	return names, rows.Err()
}

// PodKey identifies a pod series in the store.
type PodKey struct {
	NodeName      string
	PodNamespace  string
	PodName       string
}

// ListPods returns distinct pod keys that have pod-level rows.
func (s *Store) ListPods(ctx context.Context) ([]PodKey, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT DISTINCT node_name, pod_namespace, pod_name FROM resource_snapshots
		 WHERE pod_namespace IS NOT NULL AND pod_namespace != '' AND pod_name IS NOT NULL AND pod_name != ''
		 ORDER BY node_name, pod_namespace, pod_name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PodKey
	for rows.Next() {
		var k PodKey
		if err := rows.Scan(&k.NodeName, &k.PodNamespace, &k.PodName); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// CountTotal returns row count (approximate health stat).
func (s *Store) CountTotal(ctx context.Context) (int64, error) {
	var c int64
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(1) FROM resource_snapshots`).Scan(&c)
	return c, err
}

// PruneOlderThan deletes rows older than cutoff (UTC).
func (s *Store) PruneOlderThan(ctx context.Context, cutoff time.Time) (int64, error) {
	cutMs := cutoff.UnixMilli()
	res, err := s.db.ExecContext(ctx, `DELETE FROM resource_snapshots WHERE ts_unix_ms < ?`, cutMs)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// Close releases the DB handle.
func (s *Store) Close() error {
	if s.db == nil {
		return nil
	}
	return s.db.Close()
}

// DefaultPath returns default DB path from env DATA_DIR.
func DefaultPath() string {
	dir := os.Getenv("DATA_DIR")
	if dir == "" {
		dir = "."
	}
	return filepath.Join(dir, "insight-hub.db")
}

// RetentionDays from env, default 14.
func RetentionDays() int {
	if v := os.Getenv("RETENTION_DAYS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return 14
}
