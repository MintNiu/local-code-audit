package example;

import java.net.URI;
import java.util.Set;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
final class RedirectController {
    private static final Set<String> ALLOWED_HOSTS = Set.of("app.example.com");

    @GetMapping("/continue")
    ResponseEntity<Void> continueTo(@RequestParam String next) {
        URI target = URI.create(next);
        if (!"https".equalsIgnoreCase(target.getScheme()) || !ALLOWED_HOSTS.contains(target.getHost())) {
            return ResponseEntity.badRequest().build();
        }
        return ResponseEntity.status(302).location(target).build();
    }
}
