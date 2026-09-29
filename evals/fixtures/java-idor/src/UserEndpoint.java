package example;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

@RestController
final class UserEndpoint {
    private final UserRepository users;

    UserEndpoint(UserRepository users) {
        this.users = users;
    }

    @GetMapping("/users/{userId}")
    User get(CurrentUser currentUser, @PathVariable Long userId) {
        return users.findById(userId);
    }

    interface UserRepository {
        User findById(Long userId);
    }

    record CurrentUser(Long tenantId) {}
    record User(Long id, String email) {}
}
