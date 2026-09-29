package example;

import java.io.IOException;

final class CommandRunner {
    Process run() throws IOException {
        return new ProcessBuilder("git", "status", "--porcelain").start();
    }
}
