-- =====================================================================
-- 03_seed.sql : dados de exemplo (FICTÍCIOS) para demonstração
-- =====================================================================
SET search_path TO pure_touch, public;

INSERT INTO unidade (nome, endereco, bairro, telefone) VALUES
 ('Pure Touch Centro',        'Av. Rio Branco, 100 - sala 1201', 'Centro',         '(21) 3000-0001'),
 ('Pure Touch Tijuca',        'Rua Conde de Bonfim, 500',        'Tijuca',         '(21) 3000-0002'),
 ('Pure Touch Barra',         'Av. das Américas, 3000 - loja 20','Barra da Tijuca','(21) 3000-0003');

INSERT INTO categoria (nome) VALUES ('Estética Facial'), ('Estética Corporal');

INSERT INTO procedimento (categoria_id, nome, descricao, duracao_min, preco) VALUES
 (1, 'Preenchimento facial',  'Reposição de volume e contorno facial',        60, 1200.00),
 (1, 'Toxina Botulínica',     'Suavização de linhas de expressão',            30,  900.00),
 (1, 'Harmonização facial',   'Combinação de técnicas para equilíbrio facial',90, 2500.00),
 (1, 'Preenchimento labial',  'Definição e volume dos lábios',                45, 1000.00),
 (2, 'Preenchimento corporal','Contorno e volume corporal',                   60, 1800.00),
 (2, 'Massagem modeladora',   'Massagem manual para modelagem corporal',      60,  250.00),
 (2, 'Drenagem linfática',    'Redução de retenção de líquidos',              60,  200.00),
 (2, 'Radiofrequência',       'Tratamento de flacidez e gordura localizada',  45,  350.00);

INSERT INTO profissional (unidade_id, nome, registro_conselho, especialidade) VALUES
 (1, 'Dra. Camila Rocha',   'CRM-RJ 100001',    'Dermatologia'),
 (1, 'Dra. Helena Duarte',  'CRBM-RJ 20002',    'Biomedicina Estética'),
 (2, 'Dr. Rafael Menezes',  'CRM-RJ 100003',    'Dermatologia'),
 (2, 'Ana Beatriz Lopes',   'CREFITO-2 30004',  'Fisioterapia Dermatofuncional'),
 (3, 'Dra. Larissa Prado',  'CRBM-RJ 20005',    'Biomedicina Estética'),
 (3, 'Juliana Teixeira',    'CREFITO-2 30006',  'Fisioterapia Dermatofuncional');

INSERT INTO profissional_procedimento (profissional_id, procedimento_id) VALUES
 (1,1),(1,2),(1,3),(1,4),
 (2,1),(2,2),(2,4),
 (3,1),(3,2),(3,3),(3,4),(3,5),
 (4,6),(4,7),(4,8),
 (5,1),(5,2),(5,4),
 (6,5),(6,6),(6,7),(6,8);

-- Clientes cadastrados pela procedure (valida idade, senha e gera hash)
DO $$
DECLARE v_id INT;
BEGIN
    CALL sp_cadastrar_cliente('Mariana Souza',   '11111111111', 'mariana@email.com', '(21) 90000-0001', DATE '1992-03-14', 'senha1234', v_id);
    CALL sp_cadastrar_cliente('Fernanda Lima',   '22222222222', 'fernanda@email.com','(21) 90000-0002', DATE '1988-11-02', 'senha1234', v_id);
    CALL sp_cadastrar_cliente('Patrícia Gomes',  '33333333333', 'patricia@email.com','(21) 90000-0003', DATE '1995-07-21', 'senha1234', v_id);
    CALL sp_cadastrar_cliente('Renata Alves',    '44444444444', 'renata@email.com',  '(21) 90000-0004', DATE '1980-01-30', 'senha1234', v_id);
END $$;

-- Histórico (inserido direto, pois a procedure só aceita horários futuros)
INSERT INTO agendamento (cliente_id, procedimento_id, profissional_id, unidade_id, inicio, fim, status, valor_tabela, percentual_desconto, valor_final, motivo_cancelamento) VALUES
 (1, 1, 1, 1, now()::date - 30 + TIME '10:00', now()::date - 30 + TIME '11:00', 'CONCLUIDO', 1200, 0, 1200, NULL),
 (2, 6, 4, 2, now()::date - 20 + TIME '14:00', now()::date - 20 + TIME '15:00', 'CONCLUIDO',  250, 0,  250, NULL),
 (3, 8, 6, 3, now()::date - 10 + TIME '09:00', now()::date - 10 + TIME '09:45', 'CONCLUIDO',  350, 0,  350, NULL),
 (4, 2, 5, 3, now()::date - 5  + TIME '16:00', now()::date - 5  + TIME '16:30', 'CANCELADO',  900, 0,  900, 'Imprevisto pessoal');

INSERT INTO pagamento (agendamento_id, valor, forma, pago_em)
SELECT id, valor_final, 'PIX', fim FROM agendamento WHERE status = 'CONCLUIDO';
