package example;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
final class PaymentService {
    private final PaymentGateway gateway;
    private final OrderRepository orders;

    PaymentService(PaymentGateway gateway, OrderRepository orders) {
        this.gateway = gateway;
        this.orders = orders;
    }

    @Transactional
    void create(OrderRequest request) {
        gateway.charge(request.cardToken(), request.amount());
        orders.save(new Order(request.amount()));
    }

    record Order(long amount) {}
    record OrderRequest(String cardToken, long amount) {}
    interface PaymentGateway { void charge(String cardToken, long amount); }
    interface OrderRepository { void save(Order order); }
}
