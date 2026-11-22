/*
 * mclpd: the MCLP network service. REST over HTTPS and MQTT over TLS, on top of the console code in sw/common.
 *
 *   mclpd [-c /etc/mclp/mclpd.conf]
 *
 * REST (HTTP basic authentication over HTTPS; accounts in /etc/mclp/users, one "name:role:hash" per line,
 * role viewer or operator, hash from `openssl passwd -6`):
 *   GET  /api/v1/weight     net weight, unit, stable, overload, last weigh-in-motion and inference results
 *   GET  /api/v1/faults     sticky fault flags per channel
 *   GET  /api/v1/settings   calibration, filter, stability, weigh-in-motion and inference settings
 *   POST /api/v1/cmd        {"cmd": "<console command>"}: viewers may run the commands that only read
 *
 * MQTT (client of the configured broker), topics under <prefix>/<device>/:
 *   weight   every RESULT update, at most publish_hz per second (QoS 0)
 *   wim      each new weigh-in-motion result (QoS 1)
 *   inference each new result of the inference engine, the corrected weigh-in-motion estimate (QoS 1)
 *   faults   per-channel flags, on change (QoS 1, retained)
 *   status   "online", or "offline" as the last will (QoS 1, retained)
 *   cmd      subscribed: a console command line; the reply goes to cmd/result (QoS 1). The broker's ACLs
 *            decide who may publish here.
 *
 * Every command runs through console_exec, under the lock that the mclp console also takes, starting from
 * and saving to /etc/mclp/mclp.cal. "live" needs a keyboard and is refused.
 */
#include <crypt.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include <cjson/cJSON.h>
#include <microhttpd.h>
#include <mosquitto.h>

#include "backend.h"
#include "calib.h"

enum { NONE, VIEWER, OPERATOR };

static struct {
	char device[64], prefix[32], users[128], cert[128], key[128];
	char mqtt_host[128], mqtt_user[64], mqtt_password[128], mqtt_ca[128];
	int  http_port, publish_hz, mqtt_port, mqtt_tls;
} cfg = {
	.prefix = "mclp", .users = "/etc/mclp/users", .cert = "/etc/mclp/server.crt", .key = "/etc/mclp/server.key",
	.http_port = 443, .publish_hz = 10, .mqtt_port = 8883, .mqtt_tls = 1,
};

static volatile sig_atomic_t stop;
static pthread_mutex_t cmd_mx = PTHREAD_MUTEX_INITIALIZER, crypt_mx = PTHREAD_MUTEX_INITIALIZER;

static void on_signal(int s) { (void)s; stop = 1; }
static int  no_key(void) { return -1; }

/* ------------------------------------------------------------------ configuration and accounts */

static void conf_load(const char *path)
{
	FILE *f = fopen(path, "r");
	char line[256], k[64], v[192];
	if (!f) {
		fprintf(stderr, "mclpd: %s not found; defaults, MQTT off\n", path);
		return;
	}
	while (fgets(line, sizeof line, f)) {
		v[0] = 0;
		if (sscanf(line, " %63[a-z_] = %191[^\r\n]", k, v) < 1)
			continue;                             /* blank lines and # comments */
		for (char *e = v + strlen(v); e > v && e[-1] == ' '; )
			*--e = 0;
#define S(name) if (!strcmp(k, #name)) { snprintf(cfg.name, sizeof cfg.name, "%s", v); continue; }
#define I(name) if (!strcmp(k, #name)) { cfg.name = atoi(v); continue; }
		S(device) S(prefix) S(users) S(cert) S(key) S(mqtt_host) S(mqtt_user) S(mqtt_password) S(mqtt_ca)
		I(http_port) I(publish_hz) I(mqtt_port) I(mqtt_tls)
		if (!strcmp(k, "ntp_server"))
			continue;                             /* the boot script's, for ntpd */
		fprintf(stderr, "mclpd: %s: unknown setting \"%s\"\n", path, k);
	}
	fclose(f);
	if (!cfg.device[0])
		gethostname(cfg.device, sizeof cfg.device - 1);
	if (cfg.publish_hz < 1 || cfg.publish_hz > 50)
		cfg.publish_hz = 10;
}

/* Role of user/password, NONE if unknown. The file is read on every request, so edits apply at once. */
static int auth(const char *user, const char *pass)
{
	char line[512];
	int role = NONE;
	FILE *f = fopen(cfg.users, "r");
	if (!f)
		return NONE;
	while (fgets(line, sizeof line, f)) {
		char *save, *name = strtok_r(line, ":", &save), *r = strtok_r(NULL, ":", &save);
		char *hash = strtok_r(NULL, ":\r\n", &save);
		if (!name || !r || !hash || strcmp(name, user))
			continue;
		pthread_mutex_lock(&crypt_mx);            /* One crypt() at a time, ~10 ms each on the A9 */
		const char *h = crypt(pass, hash);
		int ok = h && !strcmp(h, hash);
		pthread_mutex_unlock(&crypt_mx);
		if (ok)
			role = !strcmp(r, "operator") ? OPERATOR : !strcmp(r, "viewer") ? VIEWER : NONE;
		break;
	}
	fclose(f);
	return role;
}

/* ------------------------------------------------------------------ commands and readings */

static int read_only(int argc, char **argv)
{
	static const char *any[]  = { "help", "status", "info", "w" };
	static const char *bare[] = { "wim", "nn", "faults", "stab", "decim", "fir", "cal" };
	for (unsigned i = 0; i < sizeof any / sizeof any[0]; i++)
		if (!strcmp(argv[0], any[i]))
			return 1;
	for (unsigned i = 0; i < sizeof bare / sizeof bare[0]; i++)
		if (!strcmp(argv[0], bare[i]))
			return argc == 1 || (argc == 2 && !strcmp(argv[0], "cal") && !strcmp(argv[1], "show"));
	return 0;
}

/* Runs one console command line with its output captured. Returns the JSON reply; *code is the HTTP status. */
static char *run_line(const char *line, int role, unsigned *code)
{
	char buf[256], *argv[8], *save;
	int argc = 0;
	snprintf(buf, sizeof buf, "%s", line);
	for (char *t = strtok_r(buf, " \t\r\n", &save); t && argc < 8; t = strtok_r(NULL, " \t\r\n", &save))
		argv[argc++] = t;

	cJSON *o = cJSON_CreateObject();
	cJSON_AddStringToObject(o, "cmd", line);
	const char *err = !argc                     ? "empty command"
	                : !strcmp(argv[0], "live")  ? "live needs a keyboard; read /api/v1/weight or the weight topic"
	                : role < OPERATOR && !read_only(argc, argv) ? "this command needs the operator role" : NULL;
	if (err) {
		*code = role < OPERATOR && argc ? MHD_HTTP_FORBIDDEN : MHD_HTTP_BAD_REQUEST;
		cJSON_AddBoolToObject(o, "ok", 0);
		cJSON_AddStringToObject(o, "error", err);
	} else {
		char *out = NULL;
		size_t n = 0;
		pthread_mutex_lock(&cmd_mx);              /* console output goes to stdout: capture it */
		fflush(stdout);
		FILE *saved = stdout, *mem = open_memstream(&out, &n);
		if (mem)
			stdout = mem;
		int rc = console_exec(argc, argv);
		if (mem) {
			fclose(mem);
			stdout = saved;
		}
		pthread_mutex_unlock(&cmd_mx);
		*code = rc == 2 ? MHD_HTTP_BAD_REQUEST : MHD_HTTP_OK;
		cJSON_AddBoolToObject(o, "ok", rc == 0);
		cJSON_AddStringToObject(o, "output", out ? out : "");
		free(out);
	}
	char *s = cJSON_PrintUnformatted(o);
	cJSON_Delete(o);
	return s;
}

static double now_ms(void)
{
	struct timeval t;
	gettimeofday(&t, NULL);
	return t.tv_sec * 1000.0 + t.tv_usec / 1000;
}

static cJSON *wim_json(const reading_t *r)
{
	if (!r->wim_n)
		return cJSON_CreateNull();
	cJSON *o = cJSON_CreateObject();
	cJSON_AddNumberToObject(o, "value", r->wim_value);
	cJSON_AddStringToObject(o, "unit", r->spanned ? "kg" : "counts");
	cJSON_AddNumberToObject(o, "samples", r->wim_n);
	cJSON_AddNumberToObject(o, "seconds", r->wim_n / CIC_RATE_HZ);
	return o;
}

static cJSON *nn_json(const reading_t *r)
{
	if (!r->nn_seq)
		return cJSON_CreateNull();
	cJSON *o = cJSON_CreateObject();
	cJSON_AddNumberToObject(o, "value", r->nn_value);
	cJSON_AddStringToObject(o, "unit", r->spanned ? "kg" : "counts");
	cJSON_AddNumberToObject(o, "correction", r->nn_corr);
	cJSON_AddNumberToObject(o, "seq", r->nn_seq);
	return o;
}

static cJSON *weight_json(const reading_t *r, int with_wim)
{
	cJSON *o = cJSON_CreateObject();
	cJSON_AddNumberToObject(o, "value", r->value);
	cJSON_AddStringToObject(o, "unit", r->spanned ? "kg" : "counts");
	cJSON_AddBoolToObject(o, "stable", r->stable);
	cJSON_AddBoolToObject(o, "overload", r->overload);
	cJSON_AddNumberToObject(o, "seq", r->seq);
	cJSON_AddNumberToObject(o, "time_ms", now_ms());
	if (with_wim) {
		cJSON_AddItemToObject(o, "wim", wim_json(r));
		cJSON_AddItemToObject(o, "nn", nn_json(r));
	}
	return o;
}

static cJSON *faults_json(const reading_t *r)
{
	static const struct { uint32_t bit; const char *name; } fl[] = {
		{ FLT_ERR, "ERR" }, { FLT_NOREF, "NOREF" }, { FLT_PARITY, "PARITY" }, { FLT_STALE, "STALE" },
		{ FLT_MISMATCH, "MISMATCH" },
	};
	cJSON *o = cJSON_CreateObject(), *chs = cJSON_AddArrayToObject(o, "channels");
	int any = 0;
	for (int ch = 0; ch < n_ch; ch++) {
		cJSON *names = cJSON_CreateArray();
		for (unsigned i = 0; i < sizeof fl / sizeof fl[0]; i++)
			if (r->faults[ch] & fl[i].bit)
				cJSON_AddItemToArray(names, cJSON_CreateString(fl[i].name));
		any |= r->faults[ch] != 0;
		cJSON_AddItemToArray(chs, names);
	}
	cJSON_AddBoolToObject(o, "any", any);
	return o;
}

static cJSON *settings_json(void)
{
	cal_t c;
	hw->lock();
	int e = hw->fetch(&c, sizeof c);
	hw->unlock();
	int stored = !e && cal_valid(&c) && c.n_ch == (uint32_t)n_ch;
	if (!stored)
		cal_defaults(&c, n_ch);
	double k = c.kg_per_count != 0.0 ? c.kg_per_count : 1.0;  /* user unit: kg once spanned */
	cJSON *o = cJSON_CreateObject();
	cJSON_AddBoolToObject(o, "stored", stored);
	cJSON_AddStringToObject(o, "unit", c.kg_per_count != 0.0 ? "kg" : "counts");
	cJSON_AddNumberToObject(o, "kg_per_count", c.kg_per_count);
	cJSON_AddNumberToObject(o, "zero_counts", c.zero);
	cJSON_AddNumberToObject(o, "tare", c.tare * k);
	cJSON_AddNumberToObject(o, "fir_hz", c.fir_fc);
	cJSON_AddNumberToObject(o, "decim", c.decim);
	cJSON_AddNumberToObject(o, "result_hz", CIC_RATE_HZ / c.decim);
	cJSON *s = cJSON_AddObjectToObject(o, "stability");
	cJSON_AddNumberToObject(s, "band", c.stab_band * k);
	cJSON_AddNumberToObject(s, "samples", c.stab_count);
	if (c.wim_enter == 0x7FFFFFFF) {
		cJSON_AddNullToObject(o, "wim");
	} else {
		cJSON *w = cJSON_AddObjectToObject(o, "wim");
		cJSON_AddNumberToObject(w, "enter", c.wim_enter * k);
		cJSON_AddNumberToObject(w, "exit", c.wim_exit * k);
		cJSON_AddNumberToObject(w, "level", c.wim_level / 65536.0);
	}
	cJSON *nn = cJSON_AddObjectToObject(o, "nn");
	cJSON_AddBoolToObject(nn, "enabled", c.nn_enable != 0);
	cJSON *off = cJSON_AddArrayToObject(o, "offset"), *g = cJSON_AddArrayToObject(o, "gain");
	cJSON *t = cJSON_AddArrayToObject(o, "trim");
	for (int ch = 0; ch < n_ch; ch++) {
		cJSON_AddItemToArray(off, cJSON_CreateNumber(c.offset[ch]));
		cJSON_AddItemToArray(g, cJSON_CreateNumber(from_q30(c.gain[ch])));
		cJSON_AddItemToArray(t, cJSON_CreateNumber(from_q30(c.trim[ch])));
	}
	return o;
}

static char *json_string(cJSON *o)
{
	char *s = cJSON_PrintUnformatted(o);
	cJSON_Delete(o);
	return s;
}

/* ------------------------------------------------------------------ REST */

typedef struct { size_t n; int too_big; char d[1024]; } body_t;

static enum MHD_Result reply(struct MHD_Connection *c, unsigned code, char *json)
{
	struct MHD_Response *r = MHD_create_response_from_buffer_with_free_callback(strlen(json), json, free);
	MHD_add_response_header(r, "Content-Type", "application/json");
	enum MHD_Result ret = MHD_queue_response(c, code, r);
	MHD_destroy_response(r);
	return ret;
}

static char *error_json(const char *msg)
{
	cJSON *o = cJSON_CreateObject();
	cJSON_AddBoolToObject(o, "ok", 0);
	cJSON_AddStringToObject(o, "error", msg);
	return json_string(o);
}

static enum MHD_Result handle(void *cls, struct MHD_Connection *c, const char *url, const char *method,
                              const char *version, const char *upload, size_t *upload_size, void **con_cls)
{
	(void)cls; (void)version;
	body_t *b = *con_cls;
	if (!b) {                                     /* headers only; the body follows */
		*con_cls = calloc(1, sizeof *b);
		return *con_cls ? MHD_YES : MHD_NO;
	}
	if (*upload_size) {
		if (b->n + *upload_size < sizeof b->d) {
			memcpy(b->d + b->n, upload, *upload_size);
			b->n += *upload_size;
		} else {
			b->too_big = 1;
		}
		*upload_size = 0;
		return MHD_YES;
	}

	int role = NONE;
	struct MHD_BasicAuthInfo *ai = MHD_basic_auth_get_username_password3(c);
	if (ai) {
		role = auth(ai->username, ai->password ? ai->password : "");
		MHD_free(ai);
	}
	if (role == NONE) {
		char *msg = error_json("authentication required");
		struct MHD_Response *r = MHD_create_response_from_buffer_with_free_callback(strlen(msg), msg, free);
		enum MHD_Result ret = MHD_queue_basic_auth_required_response3(c, "mclp", MHD_YES, r);
		MHD_destroy_response(r);
		return ret;
	}

	reading_t rd;
	int get = !strcmp(method, "GET"), post = !strcmp(method, "POST");
	if (get && !strcmp(url, "/api/v1/weight")) {
		console_reading(&rd);
		return reply(c, MHD_HTTP_OK, json_string(weight_json(&rd, 1)));
	}
	if (get && !strcmp(url, "/api/v1/faults")) {
		console_reading(&rd);
		return reply(c, MHD_HTTP_OK, json_string(faults_json(&rd)));
	}
	if (get && !strcmp(url, "/api/v1/settings"))
		return reply(c, MHD_HTTP_OK, json_string(settings_json()));
	if (post && !strcmp(url, "/api/v1/cmd")) {
		if (b->too_big)
			return reply(c, MHD_HTTP_CONTENT_TOO_LARGE, error_json("body over 1 KB"));
		cJSON *req = cJSON_ParseWithLength(b->d, b->n);
		const cJSON *cmd = cJSON_GetObjectItemCaseSensitive(req, "cmd");
		char *res = NULL;
		unsigned code = MHD_HTTP_BAD_REQUEST;
		if (cJSON_IsString(cmd))
			res = run_line(cmd->valuestring, role, &code);
		cJSON_Delete(req);
		return reply(c, code, res ? res : error_json("expected {\"cmd\": \"<console command>\"}"));
	}
	return reply(c, MHD_HTTP_NOT_FOUND, error_json("GET /api/v1/weight, /api/v1/faults, /api/v1/settings; "
	                                                "POST /api/v1/cmd"));
}

static void request_done(void *cls, struct MHD_Connection *c, void **con_cls, enum MHD_RequestTerminationCode t)
{
	(void)cls; (void)c; (void)t;
	free(*con_cls);
	*con_cls = NULL;
}

static char *slurp(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	char *s = calloc(1, 65536);
	if (s && !fread(s, 1, 65535, f)) {
		free(s);
		s = NULL;
	}
	fclose(f);
	return s;
}

static struct MHD_Daemon *rest_start(void)
{
	char *key = slurp(cfg.key), *cert = slurp(cfg.cert);
	if (!key || !cert) {
		fprintf(stderr, "mclpd: no TLS key or certificate (%s, %s); REST off\n", cfg.key, cfg.cert);
		return NULL;
	}
	struct MHD_Daemon *d = MHD_start_daemon(
		MHD_USE_THREAD_PER_CONNECTION | MHD_USE_INTERNAL_POLLING_THREAD | MHD_USE_TLS | MHD_USE_ERROR_LOG,
		(uint16_t)cfg.http_port, NULL, NULL, handle, NULL,
		MHD_OPTION_HTTPS_MEM_KEY, key, MHD_OPTION_HTTPS_MEM_CERT, cert,
		MHD_OPTION_NOTIFY_COMPLETED, request_done, NULL,
		MHD_OPTION_CONNECTION_TIMEOUT, 30u, MHD_OPTION_END);
	if (!d)
		fprintf(stderr, "mclpd: HTTPS on port %d failed to start\n", cfg.http_port);
	else
		fprintf(stderr, "mclpd: HTTPS on port %d\n", cfg.http_port);
	return d;                                     /* key and cert stay allocated while the daemon runs */
}

/* ------------------------------------------------------------------ MQTT */

static struct mosquitto *mq;
static pthread_t mq_thread;
static volatile int mq_up, faults_due;
static volatile unsigned mq_retry = 2;           /* seconds to the next attempt after an error libmosquitto ends on */

static void topic(char *t, size_t n, const char *leaf)
{
	snprintf(t, n, "%s/%s/%s", cfg.prefix, cfg.device, leaf);
}

static void publish(const char *leaf, char *json, int qos, int retain)
{
	char t[256];
	topic(t, sizeof t, leaf);
	mosquitto_publish(mq, NULL, t, (int)strlen(json), json, qos, retain);
	free(json);
}

static void on_connect(struct mosquitto *m, void *u, int rc)
{
	(void)u;
	char t[256];
	if (rc) {
		fprintf(stderr, "mclpd: broker refused the connection: %s\n", mosquitto_connack_string(rc));
		return;
	}
	fprintf(stderr, "mclpd: connected to %s:%d\n", cfg.mqtt_host, cfg.mqtt_port);
	mq_retry = 2;
	topic(t, sizeof t, "status");
	mosquitto_publish(m, NULL, t, 6, "online", 1, true);
	topic(t, sizeof t, "cmd");
	mosquitto_subscribe(m, NULL, t, 1);
	faults_due = 1;
	mq_up = 1;
}

static void on_disconnect(struct mosquitto *m, void *u, int rc)
{
	(void)m; (void)u;
	mq_up = 0;
	if (rc)
		fprintf(stderr, "mclpd: lost the broker (%s); reconnecting\n", mosquitto_strerror(rc));
}

static void on_message(struct mosquitto *m, void *u, const struct mosquitto_message *msg)
{
	(void)m; (void)u;
	char line[256];
	unsigned code;
	int n = msg->payloadlen < (int)sizeof line - 1 ? msg->payloadlen : (int)sizeof line - 1;
	memcpy(line, msg->payload, (size_t)n);
	line[n] = 0;
	publish("cmd/result", run_line(line, OPERATOR, &code), 1, 0);
}

/* libmosquitto retries a lost or refused connection itself (1 to 30 s), but its loop ends on a TLS error
   and does not reconnect when entered again. A clock that ntpd has not set yet causes one at boot
   (certificate not yet valid), so reconnect here: 2 s, doubling to 60 s, back to 2 s after a connection. */
/* What a failed TLS handshake turns into (libmosquitto reports some as errno EPROTO): point at the usual causes. */
static const char *tls_hint(int e)
{
	return cfg.mqtt_tls && (e == MOSQ_ERR_TLS || e == MOSQ_ERR_PROTOCOL || (e == MOSQ_ERR_ERRNO && errno == EPROTO))
	       ? " (check mqtt_ca, the broker's certificate and the clock)" : "";
}

static void *mqtt_run(void *u)
{
	(void)u;
	int e = MOSQ_ERR_SUCCESS;
	while (!stop) {
		if (e == MOSQ_ERR_SUCCESS)
			e = mosquitto_loop_forever(mq, -1, 1); /* returns on stop or on an error it does not retry */
		if (stop)
			break;
		const char *hint = tls_hint(e);
		fprintf(stderr, "mclpd: MQTT %s:%d: %s%s; retrying in %u s\n", cfg.mqtt_host, cfg.mqtt_port,
		        mosquitto_strerror(e), hint, mq_retry);
		for (unsigned s = mq_retry; s && !stop; s--)
			sleep(1);
		mq_retry = mq_retry < 30 ? 2 * mq_retry : 60;
		if (!stop)
			e = mosquitto_reconnect(mq);          /* TCP and TLS handshake; the loop takes over on success */
	}
	return NULL;
}

static void mqtt_start(void)
{
	char t[256];
	if (!cfg.mqtt_host[0]) {
		fprintf(stderr, "mclpd: no mqtt_host; MQTT off\n");
		return;
	}
	mosquitto_lib_init();
	mq = mosquitto_new(cfg.device, true, NULL);
	if (cfg.mqtt_user[0])
		mosquitto_username_pw_set(mq, cfg.mqtt_user, cfg.mqtt_password);
	if (cfg.mqtt_tls && mosquitto_tls_set(mq, cfg.mqtt_ca[0] ? cfg.mqtt_ca : NULL,
	                                      cfg.mqtt_ca[0] ? NULL : "/etc/ssl/certs", NULL, NULL, NULL))
		fprintf(stderr, "mclpd: TLS setup failed (CA %s)\n", cfg.mqtt_ca[0] ? cfg.mqtt_ca : "/etc/ssl/certs");
	topic(t, sizeof t, "status");
	mosquitto_will_set(mq, t, 7, "offline", 1, true);
	mosquitto_connect_callback_set(mq, on_connect);
	mosquitto_disconnect_callback_set(mq, on_disconnect);
	mosquitto_message_callback_set(mq, on_message);
	mosquitto_reconnect_delay_set(mq, 1, 30, true);
	int e = mosquitto_connect_async(mq, cfg.mqtt_host, cfg.mqtt_port, 30);
	if (e) {
		const char *hint = tls_hint(e);
		fprintf(stderr, "mclpd: connecting to %s:%d: %s%s; retrying\n", cfg.mqtt_host, cfg.mqtt_port,
		        mosquitto_strerror(e), hint);
	}
	mosquitto_threaded_set(mq, true);             /* our thread runs the loop; publish only queues */
	pthread_create(&mq_thread, NULL, mqtt_run, NULL);
}

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv)
{
	const char *conf = "/etc/mclp/mclpd.conf";
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-c") && i + 1 < argc)
			conf = argv[++i];
		else {
			fprintf(stderr, "usage: mclpd [-c config]\n");
			return 2;
		}
	}
	conf_load(conf);
	if (uio_open())
		return 3;
	hw = &uio_backend;
	uio_backend.getc = no_key;

	uint32_t id;
	hw->lock();
	int bad_id = id_check(&id);
	hw->unlock();
	if (bad_id) {
		fprintf(stderr, "mclpd: ID register reads %08X, expected %08Xnn: wrong bitstream\n", (unsigned)id,
		        FPGA_ID_MAP >> 8);
		return 3;
	}

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGPIPE, SIG_IGN);
	struct MHD_Daemon *rest = rest_start();
	mqtt_start();

	reading_t r, last;
	console_reading(&last);                       /* a WIM result from before the start is not new */
	while (!stop) {
		usleep(1000000u / (unsigned)cfg.publish_hz);
		console_reading(&r);
		if (mq_up) {
			if (r.seq != last.seq)
				publish("weight", json_string(weight_json(&r, 0)), 0, 0);
			if (faults_due || memcmp(r.faults, last.faults, sizeof r.faults)) {
				publish("faults", json_string(faults_json(&r)), 1, 1);
				faults_due = 0;
			}
			if (r.wim_n && (r.wim_n != last.wim_n || r.wim_sum != last.wim_sum))
				publish("wim", json_string(wim_json(&r)), 1, 0);
			if (r.nn_seq && r.nn_seq != last.nn_seq)
				publish("inference", json_string(nn_json(&r)), 1, 0);
		}
		last = r;
	}

	if (mq) {
		char t[256];
		topic(t, sizeof t, "status");
		mosquitto_publish(mq, NULL, t, 7, "offline", 1, true);
		mosquitto_disconnect(mq);
		pthread_join(mq_thread, NULL);
	}
	if (rest)
		MHD_stop_daemon(rest);
	return 0;
}
