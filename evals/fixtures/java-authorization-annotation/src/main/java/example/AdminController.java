package example;

import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
final class AdminController {
    // @PreAuthorize("hasAuthority('admin:write')")
    @PostMapping("/admin/reindex")
    void reindex() {
        rebuildIndex();
    }

    private void rebuildIndex() {}
}
