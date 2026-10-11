package example;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;

final class PathReader {
    String read(Path root, String filename) throws IOException {
        if (root == null || filename == null || filename.isBlank()) {
            throw new IllegalArgumentException("root and filename are required");
        }
        Path canonicalRoot = root.toRealPath();
        Path target = canonicalRoot.resolve(filename).normalize();
        if (!target.startsWith(canonicalRoot)) {
            throw new IllegalArgumentException("path escapes root");
        }
        if (Files.isSymbolicLink(target)) {
            throw new IllegalArgumentException("symbolic links are not allowed");
        }
        Path realTarget = target.toRealPath(LinkOption.NOFOLLOW_LINKS);
        if (Files.isSymbolicLink(realTarget) || !realTarget.startsWith(canonicalRoot)) {
            throw new IllegalArgumentException("path escapes root");
        }
        return Files.readString(realTarget);
    }
}
