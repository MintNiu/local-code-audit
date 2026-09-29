package example;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.client.RestTemplate;

final class RemoteFetcher {
    String fetch(HttpServletRequest request) {
        String target = request.getParameter("url");
        return new RestTemplate().getForObject(target, String.class);
    }
}
