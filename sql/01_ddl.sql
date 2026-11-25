-- =====================================================================
-- AP3 - Projeto Final | Banco de Dados da clínica estética Pure Touch
-- 01_ddl.sql : criação do schema, tabelas, restrições e índices (DDL)
-- SGBD: PostgreSQL 13+
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- necessária para a EXCLUDE constraint (anti-conflito de horário)
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- hash de senha (crypt / gen_salt)

DROP SCHEMA IF EXISTS pure_touch CASCADE;
CREATE SCHEMA pure_touch;
SET search_path TO pure_touch, public;

-- ---------------------------------------------------------------------
-- Contexto: EQUIPE / UNIDADES
-- ---------------------------------------------------------------------
CREATE TABLE unidade (
    id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome      VARCHAR(80)  NOT NULL UNIQUE,
    endereco  VARCHAR(150) NOT NULL,
    bairro    VARCHAR(60)  NOT NULL,
    cidade    VARCHAR(60)  NOT NULL DEFAULT 'Rio de Janeiro',
    uf        CHAR(2)      NOT NULL DEFAULT 'RJ',
    telefone  VARCHAR(20)
);

-- ---------------------------------------------------------------------
-- Contexto: CATÁLOGO (Estética Facial / Estética Corporal do site)
-- ---------------------------------------------------------------------
CREATE TABLE categoria (
    id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome  VARCHAR(40) NOT NULL UNIQUE          -- 'Estética Facial', 'Estética Corporal'
);

CREATE TABLE procedimento (
    id           INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    categoria_id INT           NOT NULL REFERENCES categoria(id),
    nome         VARCHAR(80)   NOT NULL UNIQUE,
    descricao    TEXT,
    duracao_min  INT           NOT NULL CHECK (duracao_min BETWEEN 15 AND 240),
    preco        NUMERIC(10,2) NOT NULL CHECK (preco >= 0),
    ativo        BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE profissional (
    id               INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    unidade_id       INT          NOT NULL REFERENCES unidade(id),
    nome             VARCHAR(100) NOT NULL,
    registro_conselho VARCHAR(30) NOT NULL UNIQUE,   -- ex.: CRM / CRBM / CREFITO
    especialidade    VARCHAR(60)  NOT NULL,
    ativo            BOOLEAN      NOT NULL DEFAULT TRUE
);

-- N:N  quem executa o quê
CREATE TABLE profissional_procedimento (
    profissional_id INT NOT NULL REFERENCES profissional(id) ON DELETE CASCADE,
    procedimento_id INT NOT NULL REFERENCES procedimento(id) ON DELETE CASCADE,
    PRIMARY KEY (profissional_id, procedimento_id)
);

-- ---------------------------------------------------------------------
-- Contexto: CLIENTES (login / ícone de usuário do site)
-- ---------------------------------------------------------------------
CREATE TABLE cliente (
    id               INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome             VARCHAR(100) NOT NULL,
    cpf              CHAR(11)     NOT NULL UNIQUE CHECK (cpf ~ '^[0-9]{11}$'),
    email            VARCHAR(120) NOT NULL UNIQUE CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    telefone         VARCHAR(20),
    data_nascimento  DATE         NOT NULL,
    senha_hash       TEXT         NOT NULL,
    criado_em        TIMESTAMP    NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Contexto: PROMOÇÕES (banner "Black Friday - até 50% de desconto")
-- ---------------------------------------------------------------------
CREATE TABLE promocao (
    id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome    VARCHAR(80) NOT NULL,
    inicio  DATE        NOT NULL,
    fim     DATE        NOT NULL,
    ativa   BOOLEAN     NOT NULL DEFAULT TRUE,
    CHECK (fim >= inicio)
);

CREATE TABLE promocao_procedimento (
    promocao_id     INT          NOT NULL REFERENCES promocao(id) ON DELETE CASCADE,
    procedimento_id INT          NOT NULL REFERENCES procedimento(id),
    percentual      NUMERIC(5,2) NOT NULL CHECK (percentual > 0 AND percentual <= 50),  -- "até 50%"
    PRIMARY KEY (promocao_id, procedimento_id)
);

-- ---------------------------------------------------------------------
-- Contexto: AGENDAMENTO ("Agende sua consulta")  -> raiz de agregado
-- ---------------------------------------------------------------------
CREATE TABLE agendamento (
    id                  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cliente_id          INT           NOT NULL REFERENCES cliente(id),
    procedimento_id     INT           NOT NULL REFERENCES procedimento(id),
    profissional_id     INT           NOT NULL REFERENCES profissional(id),
    unidade_id          INT           NOT NULL REFERENCES unidade(id),
    promocao_id         INT           REFERENCES promocao(id),
    inicio              TIMESTAMP     NOT NULL,
    fim                 TIMESTAMP     NOT NULL,
    status              VARCHAR(12)   NOT NULL DEFAULT 'AGENDADO'
                        CHECK (status IN ('AGENDADO','CONCLUIDO','CANCELADO','FALTOU')),
    valor_tabela        NUMERIC(10,2) NOT NULL CHECK (valor_tabela >= 0),
    percentual_desconto NUMERIC(5,2)  NOT NULL DEFAULT 0 CHECK (percentual_desconto BETWEEN 0 AND 50),
    valor_final         NUMERIC(10,2) NOT NULL CHECK (valor_final >= 0),
    motivo_cancelamento TEXT,
    criado_em           TIMESTAMP     NOT NULL DEFAULT now(),
    CHECK (fim > inicio),
    CHECK (status <> 'CANCELADO' OR motivo_cancelamento IS NOT NULL),

    -- Regra de negócio garantida pelo próprio SGBD: um profissional não pode ter
    -- dois atendimentos ativos sobrepostos, nem o cliente estar em dois lugares ao mesmo tempo.
    CONSTRAINT ex_profissional_sem_conflito
        EXCLUDE USING gist (profissional_id WITH =, tsrange(inicio, fim) WITH &&)
        WHERE (status IN ('AGENDADO','CONCLUIDO')),
    CONSTRAINT ex_cliente_sem_conflito
        EXCLUDE USING gist (cliente_id WITH =, tsrange(inicio, fim) WITH &&)
        WHERE (status IN ('AGENDADO','CONCLUIDO'))
);

CREATE INDEX ix_agendamento_cliente  ON agendamento (cliente_id);
CREATE INDEX ix_agendamento_inicio   ON agendamento (inicio);
CREATE INDEX ix_agendamento_unidade  ON agendamento (unidade_id, inicio);

-- ---------------------------------------------------------------------
-- Contexto: FINANCEIRO
-- ---------------------------------------------------------------------
CREATE TABLE pagamento (
    id              INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agendamento_id  INT           NOT NULL UNIQUE REFERENCES agendamento(id),
    valor           NUMERIC(10,2) NOT NULL CHECK (valor >= 0),
    forma           VARCHAR(20)   NOT NULL CHECK (forma IN ('PIX','CARTAO_CREDITO','CARTAO_DEBITO','DINHEIRO')),
    pago_em         TIMESTAMP     NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Auditoria (preenchida por trigger)
-- ---------------------------------------------------------------------
CREATE TABLE log_agendamento (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agendamento_id   INT         NOT NULL,
    status_anterior  VARCHAR(12),
    status_novo      VARCHAR(12) NOT NULL,
    alterado_em      TIMESTAMP   NOT NULL DEFAULT now(),
    usuario_bd       VARCHAR(63) NOT NULL DEFAULT current_user
);

COMMENT ON TABLE agendamento IS 'Raiz do agregado Agendamento (contexto Agendamento).';
COMMENT ON CONSTRAINT ex_profissional_sem_conflito ON agendamento IS 'Impede horários sobrepostos para o mesmo profissional.';
