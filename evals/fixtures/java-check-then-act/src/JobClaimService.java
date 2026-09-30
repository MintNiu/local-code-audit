package example;

import org.springframework.stereotype.Service;

@Service
final class JobClaimService {
    private boolean claimed;

    boolean claim() {
        if (!claimed) {
            claimed = true;
            return true;
        }
        return false;
    }
}
