package example;

import java.nio.file.Files;
import java.nio.file.Path;

final class PathReader {
    String read(Path root, String filename) throws Exception {
        Path target = root.resolve(filename);
        return Files.readString(target);
    }
}
