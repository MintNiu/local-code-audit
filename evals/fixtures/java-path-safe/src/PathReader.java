package example;

import java.nio.file.Files;
import java.nio.file.Path;

final class PathReader {
    String read(Path root, String filename) throws Exception {
        Path canonicalRoot = root.toAbsolutePath().normalize();
        Path target = canonicalRoot.resolve(filename).normalize();
        if (!target.startsWith(canonicalRoot)) {
            throw new IllegalArgumentException("path escapes root");
        }
        return Files.readString(target);
    }
}
