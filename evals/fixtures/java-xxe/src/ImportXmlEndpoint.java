package example;

import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.xml.sax.SAXException;

final class ImportXmlEndpoint {
    Document parse(HttpServletRequest request) throws IOException, SAXException {
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        return factory.newDocumentBuilder().parse(request.getInputStream());
    }
}
