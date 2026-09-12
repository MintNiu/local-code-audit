# Tenant isolation contract

Every repository lookup for tenant-owned data must constrain both `tenantId` and the resource identifier. A lookup by resource identifier alone is a cross-tenant data exposure defect.
