package example;

import java.util.concurrent.atomic.AtomicBoolean;
import org.springframework.stereotype.Service;

@Service
final class JobClaimService {
    private final AtomicBoolean claimed = new AtomicBoolean();

    boolean claim() {
        return claimed.compareAndSet(false, true);
    }
}
