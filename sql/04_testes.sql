-- =====================================================================
-- 04_testes.sql : roteiro de demonstração/testes (rode e mostre as saídas)
-- Cada bloco imprime NOTICE com o resultado esperado.
-- =====================================================================
SET search_path TO pure_touch, public;
\set ON_ERROR_STOP off

\echo '--- T1: campanha Black Friday (cursor) com 50% facial / 30% corporal'
DO $$
DECLARE v_promo INT;
BEGIN
    CALL sp_ativar_campanha('Black Friday 2026', CURRENT_DATE, CURRENT_DATE + 30, 50, 30, v_promo);
    RAISE NOTICE 'Promoção criada: id=%', v_promo;
END $$;
SELECT p.nome, p.preco, fn_valor_com_desconto(p.id) AS preco_black_friday FROM procedimento p ORDER BY p.id;

\echo '--- T2: horários livres (profissional 1, Toxina, próximo dia útil)'
SELECT * FROM fn_horarios_livres(1, 2, (CURRENT_DATE + 1 + CASE WHEN EXTRACT(DOW FROM CURRENT_DATE + 1) = 0 THEN 1 ELSE 0 END)) LIMIT 5;

\echo '--- T3: agendamento válido com desconto aplicado'
DO $$
DECLARE v_dia DATE := CURRENT_DATE + 2 + CASE WHEN EXTRACT(DOW FROM CURRENT_DATE + 2) = 0 THEN 1 ELSE 0 END;
        v_id INT;
BEGIN
    CALL sp_agendar_atendimento(1, 2, 1, v_dia + TIME '10:00', v_id);
    RAISE NOTICE 'Agendamento % criado (esperado: valor_tabela 900, desconto 50%%, final 450)', v_id;
END $$;
SELECT id, procedimento, status, valor_final FROM vw_agenda WHERE status = 'AGENDADO';

\echo '--- T4: conflito de horário (mesmo profissional) deve FALHAR'
DO $$
DECLARE v_dia DATE := CURRENT_DATE + 2 + CASE WHEN EXTRACT(DOW FROM CURRENT_DATE + 2) = 0 THEN 1 ELSE 0 END;
        v_id INT;
BEGIN
    CALL sp_agendar_atendimento(2, 2, 1, v_dia + TIME '10:15', v_id);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (erro esperado): %', SQLERRM;
END $$;

\echo '--- T5: profissional que não realiza o procedimento deve FALHAR'
DO $$
DECLARE v_id INT;
BEGIN
    CALL sp_agendar_atendimento(2, 6, 1, (CURRENT_DATE + 3) + TIME '10:00', v_id);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (erro esperado): %', SQLERRM;
END $$;

\echo '--- T6: horário no passado e fora do expediente devem FALHAR'
DO $$
DECLARE v_id INT;
BEGIN
    BEGIN CALL sp_agendar_atendimento(2, 2, 1, (now() - INTERVAL '1 day')::timestamp, v_id);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (erro esperado): %', SQLERRM; END;
    BEGIN CALL sp_agendar_atendimento(2, 2, 1, (CURRENT_DATE + 3) + TIME '19:00', v_id);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (erro esperado): %', SQLERRM; END;
END $$;

\echo '--- T7: cadastro de menor de idade e CPF duplicado devem FALHAR'
DO $$
DECLARE v_id INT;
BEGIN
    BEGIN CALL sp_cadastrar_cliente('Menor', '55555555555', 'menor@email.com', NULL, (CURRENT_DATE - INTERVAL '16 years')::date, 'senha1234', v_id);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (erro esperado): %', SQLERRM; END;
    BEGIN CALL sp_cadastrar_cliente('Duplicada', '11111111111', 'outra@email.com', NULL, DATE '1990-01-01', 'senha1234', v_id);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (erro esperado): %', SQLERRM; END;
END $$;

\echo '--- T8: cancelamento com antecedência'
DO $$
DECLARE v_id INT;
BEGIN
    SELECT id INTO v_id FROM agendamento WHERE status = 'AGENDADO' ORDER BY id DESC LIMIT 1;
    CALL sp_cancelar_agendamento(v_id, 'Cliente solicitou remarcação');
    RAISE NOTICE 'Agendamento % cancelado', v_id;
END $$;

\echo '--- T9: concluir atendimento + pagamento (cria agendamento passado direto) e marcar faltas (cursor)'
INSERT INTO agendamento (cliente_id, procedimento_id, profissional_id, unidade_id, inicio, fim, valor_tabela, valor_final)
VALUES (3, 7, 4, 2, now() - INTERVAL '2 hours', now() - INTERVAL '1 hour', 200, 200),    -- será concluído
       (4, 6, 6, 3, now() - INTERVAL '1 day',   now() - INTERVAL '23 hours', 250, 250);   -- será falta
DO $$
DECLARE v_id INT; v_faltas INT;
BEGIN
    SELECT id INTO v_id FROM agendamento WHERE procedimento_id = 7 AND status = 'AGENDADO' LIMIT 1;
    CALL sp_concluir_atendimento(v_id, 'CARTAO_CREDITO');
    CALL sp_marcar_faltas(INTERVAL '1 hour', v_faltas);
    RAISE NOTICE 'Atendimento % concluído; faltas marcadas: % (esperado 1)', v_id, v_faltas;
END $$;

\echo '--- T10: trilha de auditoria (trigger)'
SELECT agendamento_id, status_anterior, status_novo FROM log_agendamento ORDER BY id;

\echo '--- T11: relatórios (views)'
SELECT * FROM vw_faturamento_mensal ORDER BY mes, unidade;
SELECT * FROM vw_ranking_procedimentos ORDER BY receita DESC, procedimento;
