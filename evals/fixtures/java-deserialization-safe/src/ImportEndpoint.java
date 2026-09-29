package example;

import jakarta.servlet.http.HttpServletRequest;
import java.io.BufferedReader;
import java.io.IOException;

final class ImportEndpoint {
    String read(HttpServletRequest request) throws IOException {
        try (BufferedReader reader = request.getReader()) {
            return reader.readLine();
        }
    }
}
