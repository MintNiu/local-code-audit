import java.util.List;
import java.util.Set;

final class CleanupService {
    private final Repository repository;

    CleanupService(Repository repository) {
        this.repository = repository;
    }

    int cleanup(Set<String> bizTypes, int limit) {
        if (bizTypes == null || bizTypes.isEmpty()) {
            return 0;
        }
        int actualLimit = Math.max(1, Math.min(limit, 1000));
        List<FileRecord> records = TenantContext.supplyWithIgnoreTenant(
                () -> repository.list(bizTypes, actualLimit));
        int cleaned = 0;
        for (FileRecord record : records) {
            repository.recycleForTenant(record.tenantId(), record.id());
            cleaned++;
        }
        return cleaned;
    }

    interface Repository {
        List<FileRecord> list(Set<String> bizTypes, int limit);
        void recycleForTenant(long tenantId, long id);
    }

    record FileRecord(long tenantId, long id) {}

    static final class TenantContext {
        static <T> T supplyWithIgnoreTenant(java.util.function.Supplier<T> action) {
            return action.get();
        }
    }
}
