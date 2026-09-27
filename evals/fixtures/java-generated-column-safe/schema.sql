CREATE TABLE hr_employment (
    id BIGINT PRIMARY KEY,
    person_id BIGINT NOT NULL,
    status VARCHAR(32) NOT NULL,
    active_employment_person_id BIGINT
        GENERATED ALWAYS AS (CASE WHEN status = 'ACTIVE' THEN person_id ELSE NULL END) STORED
);
