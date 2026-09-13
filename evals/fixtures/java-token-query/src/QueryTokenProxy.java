package com.example.gateway;

import jakarta.servlet.http.HttpServletRequest;

public final class QueryTokenProxy {
    public String read(HttpServletRequest request) {
        return request.getParameter("x-token");
    }
}
