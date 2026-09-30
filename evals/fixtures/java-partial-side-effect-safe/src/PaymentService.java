package example;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
final class PaymentService {
    private final OrderRepository orders;
    private final OutboxRepository outbox;

    PaymentService(OrderRepository orders, OutboxRepository outbox) {
        this.orders = orders;
        this.outbox = outbox;
    }

    @Transactional
    void create(OrderRequest request) {
        Order order = orders.savePending(new Order(request.amount()));
        outbox.save(new ChargeRequested(order.id(), request.amount()));
    }

    record Order(long id, long amount) {
        Order(long amount) { this(0L, amount); }
    }
    record OrderRequest(String cardToken, long amount) {}
    record ChargeRequested(long orderId, long amount) {}
    interface OrderRepository { Order savePending(Order order); }
    interface OutboxRepository { void save(ChargeRequested event); }
}
