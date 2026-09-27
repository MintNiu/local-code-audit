package com.example.file;

import lombok.Data;

@Data
public class PlatformFileInternalClientProperties {
    private String baseUrl = "http://localhost:8080";
    private String internalToken;

    public String requireInternalToken() {
        if (internalToken == null || internalToken.isBlank()) {
            throw new IllegalStateException("platform.file.internal-token is required");
        }
        return internalToken;
    }
}
