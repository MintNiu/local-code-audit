package example;

import java.net.URL;
import java.util.Set;

final class UrlFetcher {
    private static final Set<String> DOMAIN_ALLOWLIST = Set.of("https://trusted.example");

    String fetch(String url) throws Exception {
        for (String prefix : DOMAIN_ALLOWLIST) {
            if (url.startsWith(prefix)) {
                return new URL(url).openStream().toString();
            }
        }
        return "blocked";
    }
}
