package com.example.orders;

public final class OrderService {
    private final OrderRepository repository;

    public OrderService(OrderRepository repository) {
        this.repository = repository;
    }

    public Order load(Long tenantId, Long orderId) {
        return repository.findById(orderId);
    }

    interface OrderRepository {
        Order findById(Long orderId);
    }

    record Order(Long id, Long tenantId) {}
}
