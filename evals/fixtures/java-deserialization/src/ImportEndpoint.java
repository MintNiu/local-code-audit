package example;

import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.io.ObjectInputStream;

final class ImportEndpoint {
    Object read(HttpServletRequest request) throws IOException, ClassNotFoundException {
        try (ObjectInputStream input = new ObjectInputStream(request.getInputStream())) {
            return input.readObject();
        }
    }
}
