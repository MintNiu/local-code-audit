package example;

import java.io.IOException;
import java.nio.file.Files;
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
        Path realTarget = target.toRealPath();
        if (!realTarget.startsWith(canonicalRoot)) {
            throw new IllegalArgumentException("path escapes root");
        }
        return Files.readString(realTarget);
    }
}
