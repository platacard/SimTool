// The network conditioner loaded into an app SimTool launches — see
// `SimulatorNetworkConditioner`. Plain C: it reroutes the app's TCP
// connections through a relay of its own and holds what passes to the
// condition SimTool writes.
enum SimulatorNetworkConditionerSource {
    static let source = #"""
    // SimTool's network link conditioner for one app in the iOS Simulator,
    // loaded with DYLD_INSERT_LIBRARIES by SimTool. Everything lives in
    // SIMTOOL_NETCOND_DIR:
    //
    //   condition.json   {"active": true, "downKbps": 780, "upKbps": 330,
    //                     "downDelayMs": 100, "upDelayMs": 100, "downLoss": 0, "upLoss": 0}
    //                    read again whenever it changes (looked at every 0.5 s)
    //   clients/<pid>.json  this app, rewritten every 2 s: it has the conditioner
    //
    // Every TCP connection the app opens to an address off this Mac's loopback
    // goes through a relay in this library. The app's non-blocking connect
    // returns "in progress" at once, as it always does; the relay's own thread
    // connects to the real address, waits out the handshake's round trip, and
    // only then connects the app's socket to its listener on loopback — or,
    // when the real address cannot be reached, to a port that refuses it, so
    // the app sees what it would have seen (and picks another address, as
    // Happy Eyeballs does). From then on the relay carries the bytes both
    // ways, each chunk released when the link would deliver it:
    //
    // - Delay: every chunk waits the delay of its direction, and a new
    //   connection one round trip more, as its handshake would.
    // - Bandwidth: one link the app's connections share, each way: a chunk
    //   leaves once those ahead of it have.
    // - Loss: a lost segment costs a retransmission timeout. At 100% nothing
    //   gets through: a connection does not come up, one that is up delivers
    //   nothing, and after 60 s either is refused or reset, as TCP gives up.
    //
    // The app's own threads never wait: Network.framework runs every
    // connection on one queue, and a wait there would stall them all. Changes
    // reach connections already open. QUIC (UDP 443) is refused, so HTTP/3
    // falls back to TCP, which is held to the condition; loopback (SimTool's
    // loggers), other UDP and blocking sockets pass untouched.

    #include <CoreFoundation/CoreFoundation.h>
    #include <arpa/inet.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <netinet/in.h>
    #include <netinet/tcp.h>
    #include <poll.h>
    #include <pthread.h>
    #include <stdatomic.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <sys/stat.h>
    #include <time.h>
    #include <unistd.h>

    #define LANE_CAP (512 * 1024)
    #define GIVE_UP 60.0

    typedef struct {
        int active;
        double down_bps, up_bps;        // bytes per second, 0 = any
        double down_delay, up_delay;    // seconds
        double down_loss, up_loss;      // 0…1
    } condition_t;

    static pthread_mutex_t cond_lock = PTHREAD_MUTEX_INITIALIZER;
    static condition_t cond;
    static const char *dir;
    static _Atomic long relayed;
    static _Atomic int relay_ready;

    static double now_s(void) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return ts.tv_sec + ts.tv_nsec / 1e9;
    }

    static void sleep_s(double seconds) {
        if (seconds <= 0) return;
        struct timespec ts = { (time_t)seconds, (long)((seconds - (time_t)seconds) * 1e9) };
        while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
    }

    static condition_t current(void) {
        condition_t copy;
        pthread_mutex_lock(&cond_lock);
        copy = cond;
        pthread_mutex_unlock(&cond_lock);
        return copy;
    }

    static double chance(void) { return (double)arc4random() / 4294967296.0; }

    static int loopback(const struct sockaddr *address) {
        if (!address) return 1;
        if (address->sa_family == AF_INET) {
            const struct sockaddr_in *in = (const struct sockaddr_in *)address;
            return (ntohl(in->sin_addr.s_addr) >> 24) == 127;
        }
        if (address->sa_family == AF_INET6) {
            const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)address;
            if (IN6_IS_ADDR_LOOPBACK(&in6->sin6_addr)) return 1;
            if (IN6_IS_ADDR_V4MAPPED(&in6->sin6_addr)) return in6->sin6_addr.s6_addr[12] == 127;
            return 0;
        }
        return 1;   // AF_UNIX and the rest are not the network
    }

    static int port_of(const struct sockaddr *address) {
        if (address->sa_family == AF_INET) return ntohs(((const struct sockaddr_in *)address)->sin_port);
        if (address->sa_family == AF_INET6) return ntohs(((const struct sockaddr_in6 *)address)->sin6_port);
        return 0;
    }

    static void nonblocking(int fd) {
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    }

    // ---- connections the app asked for, waiting for the relay to make them ----

    typedef struct request {
        struct request *next;
        // The app's socket, by number and identity: Network.framework guards
        // its descriptors (no dup, no close but its own), so the relay works
        // on the number and checks it is still that socket before it acts.
        int app;
        ino_t socket;
        struct sockaddr_storage dest;
        socklen_t destlen;
    } request_t;

    static pthread_mutex_t request_lock = PTHREAD_MUTEX_INITIALIZER;
    static request_t *requests;
    static int listen4 = -1, listen6 = -1, refuse4 = -1, refuse6 = -1, wake[2] = { -1, -1 };
    static struct sockaddr_in relay4, refused4;
    static struct sockaddr_in6 relay6, refused6;

    // ---- the call ----

    int simtool_connect(int s, const struct sockaddr *address, socklen_t length) {
        if (atomic_load(&relay_ready) && address && (address->sa_family == AF_INET || address->sa_family == AF_INET6)
            && !loopback(address) && length <= sizeof(struct sockaddr_storage)) {
            int type = 0;
            socklen_t typelen = sizeof(type);
            if (getsockopt(s, SOL_SOCKET, SO_TYPE, &type, &typelen) == 0) {
                if (type == SOCK_DGRAM && port_of(address) == 443) { errno = ENETUNREACH; return -1; }
                int v6 = address->sa_family == AF_INET6;
                int blocking = !(fcntl(s, F_GETFL) & O_NONBLOCK);
                struct stat st;
                if (type == SOCK_STREAM && !blocking && (v6 ? listen6 : listen4) >= 0 && fstat(s, &st) == 0) {
                    request_t *request = calloc(1, sizeof(request_t));
                    if (request) {
                        request->app = s;
                        request->socket = st.st_ino;
                        memcpy(&request->dest, address, length);
                        request->destlen = length;
                        pthread_mutex_lock(&request_lock);
                        request->next = requests;
                        requests = request;
                        pthread_mutex_unlock(&request_lock);
                        atomic_fetch_add(&relayed, 1);
                        char byte = 1;
                        write(wake[1], &byte, 1);
                        errno = EINPROGRESS;
                        return -1;
                    }
                }
            }
        }
        return connect(s, address, length);
    }

    __attribute__((used)) static struct { const void *r; const void *o; } interpose_connect
        __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&simtool_connect, (const void *)(unsigned long)&connect };

    // ---- the relay ----

    typedef struct chunk {
        struct chunk *next;
        double release;
        size_t length, offset;
        char data[];
    } chunk_t;

    typedef struct {
        chunk_t *head, *tail;
        size_t queued;
        int eof, shut;
        double held_since;   // when 100% loss began holding it back
    } lane_t;

    typedef struct conn {
        struct conn *next;
        int app;             // the app's socket, until it is attached
        ino_t socket;        // …and which socket that number was
        int client;          // the relay's end of the app's connection, once accepted
        int upstream;        // the relay's connection to the real address
        int started, connecting, attached, dead;
        int family, port;    // the app socket's, once attached: what the accept matches
        struct sockaddr_storage dest;
        socklen_t destlen;
        double opened, attach_at, attached_at;
        lane_t up, down;     // up: the app → the server
    } conn_t;

    static conn_t *conns;
    static double link_free[2];   // 0 down, 1 up

    static int blackholed(condition_t c, int up) { return c.active && (up ? c.up_loss : c.down_loss) >= 0.999; }

    static size_t slice(condition_t c, int up) {
        double bps = up ? c.up_bps : c.down_bps;
        if (!c.active || bps <= 0) return 64 * 1024;
        size_t bytes = (size_t)(bps / 20);
        if (bytes < 1460) bytes = 1460;
        return bytes > 64 * 1024 ? 64 * 1024 : bytes;
    }

    // When the link delivers these bytes: after its turn on the link, the
    // delay, and a retransmission's wait if they were lost; never before the
    // bytes ahead of them.
    static void enqueue(lane_t *lane, int up, const char *data, size_t length, condition_t c, double now) {
        chunk_t *chunk = malloc(sizeof(chunk_t) + length);
        if (!chunk) return;
        double release = now;
        if (c.active) {
            double bps = up ? c.up_bps : c.down_bps;
            if (bps > 0) {
                double start = link_free[up] > now ? link_free[up] : now;
                link_free[up] = start + length / bps;
                release = link_free[up];
            }
            release += up ? c.up_delay : c.down_delay;
            double loss = up ? c.up_loss : c.down_loss;
            if (loss > 0 && loss < 0.999 && chance() < loss) {
                double rto = 2 * (c.up_delay + c.down_delay);
                release += rto > 0.25 ? rto : 0.25;
            }
        }
        if (lane->tail && lane->tail->release > release) release = lane->tail->release;
        chunk->next = NULL;
        chunk->release = release;
        chunk->length = length;
        chunk->offset = 0;
        memcpy(chunk->data, data, length);
        if (lane->tail) lane->tail->next = chunk; else lane->head = chunk;
        lane->tail = chunk;
        lane->queued += length;
    }

    static void drop_lane(lane_t *lane) {
        while (lane->head) { chunk_t *next = lane->head->next; free(lane->head); lane->head = next; }
        lane->tail = NULL;
        lane->queued = 0;
    }

    // Moves what is due from `lane` to `to`. Returns -1 when `to` is gone.
    static int deliver(lane_t *lane, int to, double now) {
        while (lane->head && lane->head->release <= now) {
            chunk_t *chunk = lane->head;
            ssize_t sent = send(to, chunk->data + chunk->offset, chunk->length - chunk->offset, 0);
            if (sent < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 : -1;
            chunk->offset += (size_t)sent;
            lane->queued -= (size_t)sent;
            if (chunk->offset < chunk->length) return 0;
            lane->head = chunk->next;
            if (!lane->head) lane->tail = NULL;
            free(chunk);
        }
        if (lane->eof && !lane->head && !lane->shut) { shutdown(to, SHUT_WR); lane->shut = 1; }
        return 0;
    }

    // Reads what `from` has into `lane`. Returns -1 when `from` failed.
    static int take(lane_t *lane, int up, int from, condition_t c, double now) {
        char buffer[64 * 1024];
        ssize_t received = recv(from, buffer, slice(c, up), 0);
        if (received > 0) { enqueue(lane, up, buffer, (size_t)received, c, now); return 0; }
        if (received == 0) { lane->eof = 1; return 0; }
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 : -1;
    }

    static void open_conn(request_t *request) {
        conn_t *conn = calloc(1, sizeof(conn_t));
        if (!conn) { free(request); return; }
        conn->app = request->app;
        conn->socket = request->socket;
        conn->client = conn->upstream = -1;
        conn->family = request->dest.ss_family;
        memcpy(&conn->dest, &request->dest, request->destlen);
        conn->destlen = request->destlen;
        conn->opened = now_s();
        conn->next = conns;
        conns = conn;
        free(request);
    }

    static void start_upstream(conn_t *conn) {
        int fd = socket(conn->dest.ss_family, SOCK_STREAM, 0);
        if (fd < 0) { conn->dead = 1; return; }
        nonblocking(fd);
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        conn->upstream = fd;
        conn->started = 1;
        // Done or under way, the socket says which once it is writable: a
        // Mac with a network extension answers a non-blocking connect with
        // neither 0 nor -1.
        int result = connect(fd, (struct sockaddr *)&conn->dest, conn->destlen);
        if (result >= 0 || errno == EINPROGRESS) conn->connecting = 1; else conn->dead = 1;
    }

    // Still the socket the app asked about: a number the app closed and
    // reused is someone else's.
    static int still_app(conn_t *conn) {
        struct stat st;
        return conn->app >= 0 && fstat(conn->app, &st) == 0 && S_ISSOCK(st.st_mode) && st.st_ino == conn->socket;
    }

    // The app's socket connects to the relay now: its connect completes.
    static void attach(conn_t *conn, double now) {
        if (!still_app(conn)) { conn->app = -1; conn->dead = 1; return; }
        int v6 = conn->family == AF_INET6;
        int result = v6 ? connect(conn->app, (struct sockaddr *)&relay6, sizeof(relay6)) : connect(conn->app, (struct sockaddr *)&relay4, sizeof(relay4));
        if (result >= 0 || errno == EINPROGRESS) {
            struct sockaddr_storage local;
            socklen_t length = sizeof(local);
            if (getsockname(conn->app, (struct sockaddr *)&local, &length) == 0) conn->port = port_of((struct sockaddr *)&local);
        }
        conn->app = -1;
        conn->attached = 1;
        conn->attached_at = now;
        if (!conn->port) conn->dead = 1;
    }

    // The real address could not be reached: the app's connect fails, as it
    // would have — refused by a loopback port that never listens, or, where
    // the Mac's firewall drops that instead of refusing, timed out a second on.
    static void refuse(conn_t *conn) {
        if (still_app(conn)) {
            int second = 1;
            setsockopt(conn->app, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &second, sizeof(second));
            if (conn->family == AF_INET6 && refuse6 >= 0) connect(conn->app, (struct sockaddr *)&refused6, sizeof(refused6));
            else if (refuse4 >= 0) connect(conn->app, (struct sockaddr *)&refused4, sizeof(refused4));
        }
        conn->app = -1;
        conn->dead = 1;
    }

    static void accept_from(int listener) {
        for (;;) {
            struct sockaddr_storage peer;
            socklen_t peerlen = sizeof(peer);
            int client = accept(listener, (struct sockaddr *)&peer, &peerlen);
            if (client < 0) return;
            nonblocking(client);
            int one = 1;
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            int port = port_of((struct sockaddr *)&peer);
            conn_t *conn = conns;
            while (conn && !(conn->attached && conn->client < 0 && conn->port == port && conn->family == peer.ss_family)) conn = conn->next;
            if (conn) conn->client = client; else close(client);
        }
    }

    static void close_conn(conn_t *conn) {
        if (conn->app >= 0) refuse(conn);
        if (conn->client >= 0) close(conn->client);
        if (conn->upstream >= 0) close(conn->upstream);
        drop_lane(&conn->up);
        drop_lane(&conn->down);
        free(conn);
    }

    // 100% loss holds a lane back; held with bytes to deliver, or a
    // connection never reaching its server, for GIVE_UP seconds, it is reset.
    static int given_up(lane_t *lane, int held, int waiting, double now) {
        if (!held || !waiting) { lane->held_since = 0; return 0; }
        if (!lane->held_since) lane->held_since = now;
        return now - lane->held_since > GIVE_UP;
    }

    static void *relay_main(void *unused) {
        (void)unused;
        size_t capacity = 0;
        struct pollfd *fds = NULL;
        for (;;) {
            // The connections the app asked for since.
            pthread_mutex_lock(&request_lock);
            request_t *taken = requests;
            requests = NULL;
            pthread_mutex_unlock(&request_lock);
            while (taken) { request_t *next = taken->next; open_conn(taken); taken = next; }

            double now = now_s();
            condition_t c = current();
            // A new connection starts for its server at once, unless nothing gets through.
            for (conn_t *conn = conns; conn; conn = conn->next) {
                if (!conn->started && !conn->dead && !blackholed(c, 1) && !blackholed(c, 0)) start_upstream(conn);
            }
            size_t count = 0, need = 3;
            for (conn_t *conn = conns; conn; conn = conn->next) need += 2;
            if (need > capacity) {
                struct pollfd *grown = realloc(fds, need * 2 * sizeof(struct pollfd));
                if (!grown) { sleep_s(0.05); continue; }
                fds = grown;
                capacity = need * 2;
            }
            fds[count++] = (struct pollfd){ wake[0], POLLIN, 0 };
            fds[count++] = (struct pollfd){ listen4, POLLIN, 0 };
            fds[count++] = (struct pollfd){ listen6, POLLIN, 0 };
            double next = now + 0.25;
            for (conn_t *conn = conns; conn; conn = conn->next) {
                short client = 0, upstream = 0;
                int up_open = conn->started && !conn->connecting;
                if (conn->client >= 0 && !conn->up.eof && conn->up.queued < LANE_CAP) client |= POLLIN;
                if (up_open && conn->client >= 0 && !conn->down.eof && conn->down.queued < LANE_CAP) upstream |= POLLIN;
                if (conn->connecting) upstream |= POLLOUT;
                if (up_open && !conn->attached && conn->attach_at < next) next = conn->attach_at;
                if (conn->client >= 0 && conn->down.head && !blackholed(c, 0)) {
                    if (conn->down.head->release <= now) client |= POLLOUT;
                    else if (conn->down.head->release < next) next = conn->down.head->release;
                }
                if (up_open && conn->up.head && !blackholed(c, 1)) {
                    if (conn->up.head->release <= now) upstream |= POLLOUT;
                    else if (conn->up.head->release < next) next = conn->up.head->release;
                }
                fds[count++] = (struct pollfd){ conn->client, client, 0 };
                fds[count++] = (struct pollfd){ conn->started ? conn->upstream : -1, upstream, 0 };
            }
            int timeout = (int)((next - now) * 1000);
            poll(fds, (nfds_t)count, timeout < 1 ? 1 : timeout);
            now = now_s();
            c = current();
            if (fds[0].revents) { char sink[64]; while (read(wake[0], sink, sizeof(sink)) > 0) {} }
            if (fds[1].revents & POLLIN) accept_from(listen4);
            if (fds[2].revents & POLLIN) accept_from(listen6);
            // The connections polled, in the order they were; new ones join next round.
            size_t index = 3;
            for (conn_t *conn = conns; conn; conn = conn->next) {
                short client = 0, upstream = 0;
                if (index + 1 < count) { client = fds[index++].revents; upstream = fds[index++].revents; }
                if (conn->dead) continue;
                if (!conn->started) {
                    // At 100% loss a connection waits to reach its server, and gives up.
                    if (blackholed(c, 1) || blackholed(c, 0)) { if (now - conn->opened > GIVE_UP) refuse(conn); }
                    else start_upstream(conn);
                    if (conn->dead) { refuse(conn); continue; }
                }
                if (conn->connecting && (upstream & (POLLOUT | POLLERR | POLLHUP))) {
                    int error = 0;
                    socklen_t length = sizeof(error);
                    getsockopt(conn->upstream, SOL_SOCKET, SO_ERROR, &error, &length);
                    if (error) { refuse(conn); continue; }
                    conn->connecting = 0;
                    // The handshake's round trip, before the app's connect completes.
                    conn->attach_at = now + (c.active ? c.up_delay + c.down_delay : 0);
                    upstream &= ~POLLOUT;
                }
                if (conn->connecting && now - conn->opened > GIVE_UP) { refuse(conn); continue; }
                if (conn->started && !conn->connecting && !conn->attached && now >= conn->attach_at && !blackholed(c, 0)) attach(conn, now);
                if (conn->attached && conn->client < 0) { if (now - conn->attached_at > 5) conn->dead = 1; continue; }
                if (!conn->attached || conn->dead) continue;
                if ((client & (POLLIN | POLLHUP | POLLERR)) && take(&conn->up, 1, conn->client, c, now) != 0) conn->dead = 1;
                if (!conn->dead && (upstream & (POLLIN | POLLHUP | POLLERR)) && take(&conn->down, 0, conn->upstream, c, now) != 0) conn->dead = 1;
                if (!conn->dead && !blackholed(c, 1) && deliver(&conn->up, conn->upstream, now) != 0) conn->dead = 1;
                if (!conn->dead && !blackholed(c, 0) && deliver(&conn->down, conn->client, now) != 0) conn->dead = 1;
                if (given_up(&conn->up, blackholed(c, 1), conn->up.head != NULL, now) || given_up(&conn->down, blackholed(c, 0), conn->down.head != NULL, now)) conn->dead = 1;
                if (conn->up.shut && conn->down.shut) conn->dead = 1;
            }
            conn_t **at = &conns;
            while (*at) {
                conn_t *conn = *at;
                if (conn->dead) { *at = conn->next; close_conn(conn); } else at = &conn->next;
            }
        }
        return NULL;
    }

    // A loopback port: the relay's listener, or (`listens` 0) one that is
    // bound and never listens, so a connect to it is refused.
    static int listener(int family, int listens) {
        int fd = socket(family, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        struct sockaddr_storage address;
        memset(&address, 0, sizeof(address));
        socklen_t length;
        if (family == AF_INET) {
            struct sockaddr_in *in = (struct sockaddr_in *)&address;
            in->sin_len = sizeof(*in);
            in->sin_family = AF_INET;
            in->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            length = sizeof(*in);
        } else {
            struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)&address;
            in6->sin6_len = sizeof(*in6);
            in6->sin6_family = AF_INET6;
            in6->sin6_addr = in6addr_loopback;
            length = sizeof(*in6);
        }
        if (bind(fd, (struct sockaddr *)&address, length) != 0 || (listens && listen(fd, 128) != 0) || getsockname(fd, (struct sockaddr *)&address, &length) != 0) {
            close(fd);
            return -1;
        }
        if (family == AF_INET) memcpy(listens ? (void *)&relay4 : (void *)&refused4, &address, sizeof(struct sockaddr_in));
        else memcpy(listens ? (void *)&relay6 : (void *)&refused6, &address, sizeof(struct sockaddr_in6));
        if (listens) fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        return fd;
    }

    // ---- the condition and the heartbeat ----

    static double number(const char *json, const char *key) {
        char needle[64];
        snprintf(needle, sizeof(needle), "\"%s\"", key);
        const char *at = strstr(json, needle);
        if (!at) return 0;
        at = strchr(at + strlen(needle), ':');
        return at ? strtod(at + 1, NULL) : 0;
    }

    static void load_condition(void) {
        char path[1024];
        snprintf(path, sizeof(path), "%s/condition.json", dir);
        FILE *file = fopen(path, "r");
        condition_t next = { 0 };
        if (file) {
            char json[4096];
            size_t length = fread(json, 1, sizeof(json) - 1, file);
            fclose(file);
            json[length] = 0;
            const char *flag = strstr(json, "\"active\"");
            const char *yes = flag ? strstr(flag, "true") : NULL;
            next.active = yes && yes - flag < 16;
            next.down_bps = number(json, "downKbps") * 1000 / 8;
            next.up_bps = number(json, "upKbps") * 1000 / 8;
            next.down_delay = number(json, "downDelayMs") / 1000;
            next.up_delay = number(json, "upDelayMs") / 1000;
            next.down_loss = number(json, "downLoss") / 100;
            next.up_loss = number(json, "upLoss") / 100;
        }
        pthread_mutex_lock(&cond_lock);
        cond = next;
        pthread_mutex_unlock(&cond_lock);
        char byte = 1;
        if (wake[1] >= 0) write(wake[1], &byte, 1);
    }

    static void heartbeat(const char *bundle) {
        char folder[1024], path[1100], temporary[1200];
        snprintf(folder, sizeof(folder), "%s/clients", dir);
        mkdir(folder, 0755);
        snprintf(path, sizeof(path), "%s/%d.json", folder, getpid());
        snprintf(temporary, sizeof(temporary), "%s.tmp", path);
        FILE *file = fopen(temporary, "w");
        if (!file) return;
        struct timespec wall;
        clock_gettime(CLOCK_REALTIME, &wall);
        fprintf(file, "{\"bundleId\":\"%s\",\"pid\":%d,\"connections\":%ld,\"at\":%.3f}", bundle, getpid(),
                atomic_load(&relayed), wall.tv_sec + wall.tv_nsec / 1e9);
        fclose(file);
        rename(temporary, path);
    }

    static void *watch(void *unused) {
        (void)unused;
        char bundle[256] = "unknown";
        CFBundleRef main = CFBundleGetMainBundle();
        CFStringRef identifier = main ? CFBundleGetIdentifier(main) : NULL;
        if (identifier) CFStringGetCString(identifier, bundle, sizeof(bundle), kCFStringEncodingUTF8);
        char path[1024];
        snprintf(path, sizeof(path), "%s/condition.json", dir);
        struct timespec seen = { 0 };
        for (int tick = 0;; tick++) {
            struct stat st;
            if (stat(path, &st) == 0 && (st.st_mtimespec.tv_sec != seen.tv_sec || st.st_mtimespec.tv_nsec != seen.tv_nsec)) {
                seen = st.st_mtimespec;
                load_condition();
            }
            if (tick % 4 == 0) heartbeat(bundle);
            sleep_s(0.5);
        }
        return NULL;
    }

    __attribute__((constructor)) static void start(void) {
        dir = getenv("SIMTOOL_NETCOND_DIR");
        if (!dir || !*dir) return;
        load_condition();
        if (pipe(wake) == 0) {
            fcntl(wake[0], F_SETFL, O_NONBLOCK);
            fcntl(wake[1], F_SETFL, O_NONBLOCK);
            listen4 = listener(AF_INET, 1);
            listen6 = listener(AF_INET6, 1);
            refuse4 = listener(AF_INET, 0);
            refuse6 = listener(AF_INET6, 0);
            pthread_t relay;
            if (listen4 >= 0 && pthread_create(&relay, NULL, relay_main, NULL) == 0) {
                pthread_detach(relay);
                atomic_store(&relay_ready, 1);
            }
        }
        pthread_t thread;
        if (pthread_create(&thread, NULL, watch, NULL) == 0) pthread_detach(thread);
    }
    """#
}
