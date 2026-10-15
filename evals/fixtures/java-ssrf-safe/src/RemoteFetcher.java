package example;

import java.net.URI;
import java.util.Set;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestTemplate;

final class RemoteFetcher {
    private static final Set<String> ALLOWED_HOSTS = Set.of("api.internal.example");
    private static final RestTemplate CLIENT;

    static {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(5000);
        requestFactory.setReadTimeout(5000);
        CLIENT = new RestTemplate(requestFactory);
    }

    String fetch(String target) {
        URI uri = URI.create(target);
        if (!"https".equalsIgnoreCase(uri.getScheme()) || !ALLOWED_HOSTS.contains(uri.getHost())) {
            throw new IllegalArgumentException("unsupported target");
        }
        return CLIENT.getForObject(uri, String.class);
    }
}
