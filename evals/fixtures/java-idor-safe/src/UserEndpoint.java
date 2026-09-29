package example;

import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

@RestController
final class UserEndpoint {
    private final UserRepository users;

    UserEndpoint(UserRepository users) {
        this.users = users;
    }

    @PreAuthorize("hasAuthority('user:read')")
    @GetMapping("/users/{userId}")
    User get(CurrentUser currentUser, @PathVariable Long userId) {
        return users.findByTenantIdAndId(currentUser.tenantId(), userId);
    }

    interface UserRepository {
        User findByTenantIdAndId(Long tenantId, Long userId);
    }

    record CurrentUser(Long tenantId) {}
    record User(Long id, String email) {}
}
