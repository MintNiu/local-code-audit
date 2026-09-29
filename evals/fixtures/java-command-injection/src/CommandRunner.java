package example;

import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;

final class CommandRunner {
    Process run(HttpServletRequest request) throws IOException {
        String command = request.getParameter("command");
        return new ProcessBuilder("sh", "-c", command).start();
    }
}
