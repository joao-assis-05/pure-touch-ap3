-- =====================================================================
-- 02_procedures.sql : procedures, funções, triggers e views
-- =====================================================================
SET search_path TO pure_touch, public;

-- ---------------------------------------------------------------------
-- FUNÇÃO: melhor desconto vigente para um procedimento em uma data
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_melhor_promocao(p_procedimento_id INT, p_data DATE)
RETURNS TABLE (promocao_id INT, percentual NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT pp.promocao_id, pp.percentual
      FROM promocao_procedimento pp
      JOIN promocao pr ON pr.id = pp.promocao_id
     WHERE pp.procedimento_id = p_procedimento_id
       AND pr.ativa
       AND p_data BETWEEN pr.inicio AND pr.fim
     ORDER BY pp.percentual DESC
     LIMIT 1;
$$;

-- ---------------------------------------------------------------------
-- FUNÇÃO: preço final de um procedimento em uma data (com desconto, se houver)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_valor_com_desconto(p_procedimento_id INT, p_data DATE DEFAULT CURRENT_DATE)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_preco NUMERIC(10,2);
    v_perc  NUMERIC := 0;
BEGIN
    SELECT preco INTO v_preco FROM procedimento WHERE id = p_procedimento_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Procedimento % não encontrado', p_procedimento_id;
    END IF;

    SELECT COALESCE(MAX(percentual), 0) INTO v_perc FROM fn_melhor_promocao(p_procedimento_id, p_data);
    RETURN ROUND(v_preco * (1 - v_perc / 100), 2);
END;
$$;

-- ---------------------------------------------------------------------
-- FUNÇÃO: horários livres de um profissional para um procedimento em um dia
-- (alimenta a tela "Agende sua consulta" do site). Expediente 09h-18h, passos de 30 min.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_horarios_livres(p_profissional_id INT, p_procedimento_id INT, p_data DATE)
RETURNS TABLE (inicio TIMESTAMP, fim TIMESTAMP)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_dur INT;
BEGIN
    SELECT duracao_min INTO v_dur FROM procedimento WHERE id = p_procedimento_id AND ativo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Procedimento % inexistente ou inativo', p_procedimento_id;
    END IF;

    -- domingo não há atendimento
    IF EXTRACT(DOW FROM p_data) = 0 THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT s.slot, s.slot + make_interval(mins => v_dur)
      FROM generate_series(p_data + TIME '09:00',
                           p_data + TIME '18:00' - make_interval(mins => v_dur),
                           INTERVAL '30 minutes') AS s(slot)
     WHERE s.slot > now()
       AND NOT EXISTS (
            SELECT 1 FROM agendamento a
             WHERE a.profissional_id = p_profissional_id
               AND a.status IN ('AGENDADO','CONCLUIDO')
               AND tsrange(a.inicio, a.fim) && tsrange(s.slot, s.slot + make_interval(mins => v_dur))
       )
     ORDER BY s.slot;
END;
$$;

-- ---------------------------------------------------------------------
-- PROCEDURE: cadastrar cliente (tela de login / criar conta)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_cadastrar_cliente(
    p_nome VARCHAR, p_cpf CHAR, p_email VARCHAR, p_telefone VARCHAR,
    p_nascimento DATE, p_senha_texto TEXT,
    INOUT p_cliente_id INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_nascimento > CURRENT_DATE - INTERVAL '18 years' THEN
        RAISE EXCEPTION 'Cadastro permitido apenas para maiores de 18 anos';
    END IF;
    IF length(p_senha_texto) < 8 THEN
        RAISE EXCEPTION 'A senha deve ter pelo menos 8 caracteres';
    END IF;

    INSERT INTO cliente (nome, cpf, email, telefone, data_nascimento, senha_hash)
    VALUES (p_nome, p_cpf, lower(p_email), p_telefone, p_nascimento, crypt(p_senha_texto, gen_salt('bf')))
    RETURNING id INTO p_cliente_id;

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'CPF ou e-mail já cadastrado';
    WHEN check_violation THEN
        RAISE EXCEPTION 'CPF (11 dígitos) ou e-mail em formato inválido';
END;
$$;

-- ---------------------------------------------------------------------
-- PROCEDURE: agendar atendimento (botão "Agende sua consulta")
-- Valida regras, aplica a melhor promoção vigente e grava o agendamento.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_agendar_atendimento(
    p_cliente_id INT, p_procedimento_id INT, p_profissional_id INT, p_inicio TIMESTAMP,
    INOUT p_agendamento_id INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_dur      INT;
    v_preco    NUMERIC(10,2);
    v_unidade  INT;
    v_fim      TIMESTAMP;
    v_promo    INT;
    v_perc     NUMERIC := 0;
    v_final    NUMERIC(10,2);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cliente WHERE id = p_cliente_id) THEN
        RAISE EXCEPTION 'Cliente % não encontrado', p_cliente_id;
    END IF;

    SELECT duracao_min, preco INTO v_dur, v_preco
      FROM procedimento WHERE id = p_procedimento_id AND ativo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Procedimento % inexistente ou inativo', p_procedimento_id;
    END IF;

    SELECT unidade_id INTO v_unidade
      FROM profissional WHERE id = p_profissional_id AND ativo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profissional % inexistente ou inativo', p_profissional_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM profissional_procedimento
                    WHERE profissional_id = p_profissional_id AND procedimento_id = p_procedimento_id) THEN
        RAISE EXCEPTION 'O profissional informado não realiza este procedimento';
    END IF;

    IF p_inicio <= now() THEN
        RAISE EXCEPTION 'O horário deve estar no futuro';
    END IF;

    v_fim := p_inicio + make_interval(mins => v_dur);

    IF EXTRACT(DOW FROM p_inicio) = 0
       OR p_inicio::time < TIME '09:00' OR v_fim::time > TIME '18:00' OR v_fim::date <> p_inicio::date THEN
        RAISE EXCEPTION 'Fora do expediente (segunda a sábado, das 09h às 18h)';
    END IF;

    SELECT promocao_id, percentual INTO v_promo, v_perc
      FROM fn_melhor_promocao(p_procedimento_id, p_inicio::date);
    v_perc  := COALESCE(v_perc, 0);
    v_final := ROUND(v_preco * (1 - v_perc / 100), 2);

    INSERT INTO agendamento (cliente_id, procedimento_id, profissional_id, unidade_id, promocao_id,
                             inicio, fim, valor_tabela, percentual_desconto, valor_final)
    VALUES (p_cliente_id, p_procedimento_id, p_profissional_id, v_unidade, v_promo,
            p_inicio, v_fim, v_preco, v_perc, v_final)
    RETURNING id INTO p_agendamento_id;

EXCEPTION
    WHEN exclusion_violation THEN
        RAISE EXCEPTION 'Horário indisponível: já existe atendimento para o profissional ou para o cliente neste período';
END;
$$;

-- ---------------------------------------------------------------------
-- PROCEDURE: cancelar agendamento (antecedência mínima de 2 horas)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_cancelar_agendamento(p_agendamento_id INT, p_motivo TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_status VARCHAR(12);
    v_inicio TIMESTAMP;
BEGIN
    IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
        RAISE EXCEPTION 'Informe o motivo do cancelamento';
    END IF;

    SELECT status, inicio INTO v_status, v_inicio
      FROM agendamento WHERE id = p_agendamento_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Agendamento % não encontrado', p_agendamento_id;
    END IF;
    IF v_status <> 'AGENDADO' THEN
        RAISE EXCEPTION 'Só é possível cancelar agendamentos com status AGENDADO (atual: %)', v_status;
    END IF;
    IF v_inicio - now() < INTERVAL '2 hours' THEN
        RAISE EXCEPTION 'Cancelamento exige antecedência mínima de 2 horas';
    END IF;

    UPDATE agendamento
       SET status = 'CANCELADO', motivo_cancelamento = p_motivo
     WHERE id = p_agendamento_id;
END;
$$;

-- ---------------------------------------------------------------------
-- PROCEDURE: concluir atendimento e registrar pagamento (transação única)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_concluir_atendimento(p_agendamento_id INT, p_forma_pagamento VARCHAR)
LANGUAGE plpgsql AS $$
DECLARE
    v_status VARCHAR(12);
    v_inicio TIMESTAMP;
    v_valor  NUMERIC(10,2);
BEGIN
    SELECT status, inicio, valor_final INTO v_status, v_inicio, v_valor
      FROM agendamento WHERE id = p_agendamento_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Agendamento % não encontrado', p_agendamento_id;
    END IF;
    IF v_status <> 'AGENDADO' THEN
        RAISE EXCEPTION 'Só é possível concluir agendamentos AGENDADO (atual: %)', v_status;
    END IF;
    IF v_inicio > now() THEN
        RAISE EXCEPTION 'O atendimento ainda não ocorreu';
    END IF;

    UPDATE agendamento SET status = 'CONCLUIDO' WHERE id = p_agendamento_id;
    INSERT INTO pagamento (agendamento_id, valor, forma) VALUES (p_agendamento_id, v_valor, p_forma_pagamento);
END;
$$;

-- ---------------------------------------------------------------------
-- PROCEDURE: marcar faltas (rotina de fechamento do dia) -- usa CURSOR explícito
-- Agendamentos AGENDADO cujo horário já passou há mais de 'p_tolerancia' viram FALTOU.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_marcar_faltas(p_tolerancia INTERVAL DEFAULT INTERVAL '1 hour', INOUT p_total INT DEFAULT 0)
LANGUAGE plpgsql AS $$
DECLARE
    cur_faltas CURSOR FOR
        SELECT id FROM agendamento
         WHERE status = 'AGENDADO' AND fim + p_tolerancia < now()
         FOR UPDATE;
    v_id INT;
BEGIN
    p_total := 0;
    OPEN cur_faltas;
    LOOP
        FETCH cur_faltas INTO v_id;
        EXIT WHEN NOT FOUND;
        UPDATE agendamento SET status = 'FALTOU' WHERE id = v_id;
        p_total := p_total + 1;
    END LOOP;
    CLOSE cur_faltas;
END;
$$;

-- ---------------------------------------------------------------------
-- PROCEDURE: ativar campanha (ex.: Black Friday "até 50%") -- usa CURSOR explícito
-- Percentual por categoria; nunca ultrapassa 50%. Retorna o id da promoção.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_ativar_campanha(
    p_nome VARCHAR, p_inicio DATE, p_fim DATE,
    p_perc_facial NUMERIC, p_perc_corporal NUMERIC,
    INOUT p_promocao_id INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    cur_proc CURSOR FOR
        SELECT p.id, c.nome AS categoria
          FROM procedimento p JOIN categoria c ON c.id = p.categoria_id
         WHERE p.ativo;
    v_proc_id   INT;
    v_categoria VARCHAR;
    v_perc      NUMERIC;
BEGIN
    IF p_fim < p_inicio THEN
        RAISE EXCEPTION 'A data final da campanha não pode ser anterior à inicial';
    END IF;

    INSERT INTO promocao (nome, inicio, fim) VALUES (p_nome, p_inicio, p_fim) RETURNING id INTO p_promocao_id;

    OPEN cur_proc;
    LOOP
        FETCH cur_proc INTO v_proc_id, v_categoria;
        EXIT WHEN NOT FOUND;

        v_perc := LEAST(50, CASE WHEN v_categoria = 'Estética Facial' THEN p_perc_facial ELSE p_perc_corporal END);
        IF v_perc > 0 THEN
            INSERT INTO promocao_procedimento (promocao_id, procedimento_id, percentual)
            VALUES (p_promocao_id, v_proc_id, v_perc);
        END IF;
    END LOOP;
    CLOSE cur_proc;
END;
$$;

-- ---------------------------------------------------------------------
-- PROCEDURE: encerrar campanha
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_encerrar_campanha(p_promocao_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE promocao SET ativa = FALSE, fim = LEAST(fim, CURRENT_DATE) WHERE id = p_promocao_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Promoção % não encontrada', p_promocao_id;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- TRIGGER: auditoria de mudança de status do agendamento
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_log_status_agendamento()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO log_agendamento (agendamento_id, status_anterior, status_novo)
        VALUES (NEW.id, NULL, NEW.status);
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO log_agendamento (agendamento_id, status_anterior, status_novo)
        VALUES (NEW.id, OLD.status, NEW.status);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_log_status_agendamento
AFTER INSERT OR UPDATE OF status ON agendamento
FOR EACH ROW EXECUTE FUNCTION trg_fn_log_status_agendamento();

-- ---------------------------------------------------------------------
-- VIEWS para relatórios
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_agenda AS
SELECT a.id, a.inicio, a.fim, a.status,
       u.nome AS unidade, pf.nome AS profissional, c.nome AS cliente,
       pr.nome AS procedimento, a.valor_final
  FROM agendamento a
  JOIN unidade u        ON u.id  = a.unidade_id
  JOIN profissional pf  ON pf.id = a.profissional_id
  JOIN cliente c        ON c.id  = a.cliente_id
  JOIN procedimento pr  ON pr.id = a.procedimento_id;

CREATE OR REPLACE VIEW vw_faturamento_mensal AS
SELECT date_trunc('month', pg.pago_em)::date AS mes,
       u.nome AS unidade,
       COUNT(*)            AS atendimentos,
       SUM(pg.valor)       AS faturamento,
       ROUND(AVG(pg.valor), 2) AS ticket_medio
  FROM pagamento pg
  JOIN agendamento a ON a.id = pg.agendamento_id
  JOIN unidade u     ON u.id = a.unidade_id
 GROUP BY 1, 2;

CREATE OR REPLACE VIEW vw_ranking_procedimentos AS
SELECT pr.nome AS procedimento, c.nome AS categoria,
       COUNT(*) FILTER (WHERE a.status = 'CONCLUIDO') AS concluidos,
       COUNT(*) FILTER (WHERE a.status = 'CANCELADO') AS cancelados,
       COALESCE(SUM(a.valor_final) FILTER (WHERE a.status = 'CONCLUIDO'), 0) AS receita
  FROM procedimento pr
  JOIN categoria c ON c.id = pr.categoria_id
  LEFT JOIN agendamento a ON a.procedimento_id = pr.id
 GROUP BY pr.nome, c.nome;
