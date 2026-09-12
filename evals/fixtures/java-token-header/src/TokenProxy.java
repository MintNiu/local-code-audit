package com.example.gateway;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

public final class TokenProxy {
    private final HttpClient client = HttpClient.newHttpClient();

    public HttpResponse<String> forward(String token) throws Exception {
        HttpRequest request = HttpRequest.newBuilder(URI.create("https://internal.example/data"))
                .header("X-Token", token)
                .GET()
                .build();
        return client.send(request, HttpResponse.BodyHandlers.ofString());
    }
}
