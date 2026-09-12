package com.example.gateway;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

public final class TokenProxy {
    private final HttpClient client = HttpClient.newHttpClient();

    public HttpResponse<String> forward(String token) throws Exception {
        URI target = URI.create("https://internal.example/data?x-token=" + token);
        return client.send(HttpRequest.newBuilder(target).GET().build(), HttpResponse.BodyHandlers.ofString());
    }
}
