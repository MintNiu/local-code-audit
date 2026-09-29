package example;

import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;

final class PasswordHasher {
    private final BCryptPasswordEncoder encoder = new BCryptPasswordEncoder();

    String hash(String password) {
        return encoder.encode(password);
    }

    boolean matches(String password, String storedHash) {
        return encoder.matches(password, storedHash);
    }
}
