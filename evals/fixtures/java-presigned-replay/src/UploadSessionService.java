import java.time.Duration;
import java.time.Instant;

final class UploadSessionService {
    private static final Duration TICKET_TTL = Duration.ofMinutes(15);
    private final Store store;
    private final Sessions sessions;

    UploadSessionService(Store store, Sessions sessions) {
        this.store = store;
        this.sessions = sessions;
    }

    UploadTicket issueTicket(long id, String objectKey) {
        return store.presignPut(objectKey, TICKET_TTL);
    }

    void acceptUpload(long id, UploadTicket ticket) {
        if (ticket.expiresAt().isAfter(Instant.now())) {
            store.put(ticket, ticket.objectKey());
        }
    }

    void cancel(long id, String objectKey) {
        store.delete(objectKey);
        sessions.markCancelled(id);
    }

    void complete(long id) {
        sessions.markCompleted(id);
    }

    void cleanupExpired() {
        for (Session session : sessions.findActiveExpired()) {
            store.delete(session.objectKey());
        }
    }

    interface Store {
        UploadTicket presignPut(String objectKey, Duration ttl);
        void put(UploadTicket ticket, String objectKey);
        void delete(String objectKey);
    }

    interface Sessions {
        void markCancelled(long id);
        void markCompleted(long id);
        Iterable<Session> findActiveExpired();
    }

    interface Session { String objectKey(); }
    record UploadTicket(String objectKey, Instant expiresAt) {}
}
