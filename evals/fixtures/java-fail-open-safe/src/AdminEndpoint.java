package example;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

@RestController
final class AdminEndpoint {
    private final Authorizer authorizer;
    private final UserService users;

    AdminEndpoint(Authorizer authorizer, UserService users) {
        this.authorizer = authorizer;
        this.users = users;
    }

    @DeleteMapping("/admin/users/{id}")
    ResponseEntity<Void> delete(HttpServletRequest request, @PathVariable Long id) {
        if (!isAllowed(request)) {
            return ResponseEntity.status(403).build();
        }
        users.delete(id);
        return ResponseEntity.noContent().build();
    }

    private boolean isAllowed(HttpServletRequest request) {
        try {
            return authorizer.check(request);
        } catch (RuntimeException ex) {
            return false;
        }
    }

    interface Authorizer { boolean check(HttpServletRequest request); }
    interface UserService { void delete(Long id); }
}
