package example;

import java.net.URI;
import java.util.Set;

final class UrlFetcher {
    private static final Set<String> ALLOWED_HOSTS = Set.of("trusted.example");

    String fetch(String url) {
        URI target = URI.create(url);
        if (!"https".equalsIgnoreCase(target.getScheme()) ||
                !ALLOWED_HOSTS.contains(target.getHost())) {
            throw new IllegalArgumentException("blocked");
        }
        return target.toString();
    }
}
