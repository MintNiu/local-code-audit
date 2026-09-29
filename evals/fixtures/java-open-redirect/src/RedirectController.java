package example;

import java.net.URI;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
final class RedirectController {
    @GetMapping("/continue")
    ResponseEntity<Void> continueTo(@RequestParam String next) {
        return ResponseEntity.status(302).location(URI.create(next)).build();
    }
}
