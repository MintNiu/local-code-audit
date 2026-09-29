package example;

import java.net.URI;
import java.util.Set;
import org.springframework.web.client.RestTemplate;

final class RemoteFetcher {
    private static final Set<String> ALLOWED_HOSTS = Set.of("api.internal.example");

    String fetch(String target) {
        URI uri = URI.create(target);
        if (!"https".equalsIgnoreCase(uri.getScheme()) || !ALLOWED_HOSTS.contains(uri.getHost())) {
            throw new IllegalArgumentException("unsupported target");
        }
        return new RestTemplate().getForObject(uri, String.class);
    }
}
