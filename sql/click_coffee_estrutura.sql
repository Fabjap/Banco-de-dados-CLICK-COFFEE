


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."aplicar_cupom"("p_codigo" character varying, "p_valor_compra" numeric) RETURNS numeric
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
    v_desconto numeric;
begin
    -- Calcula e valida o desconto
    v_desconto := public.calcular_desconto_cupom(
        p_codigo,
        p_valor_compra
    );

    -- Cupom inválido ou sem desconto
    if v_desconto <= 0 then
        return 0;
    end if;

    -- Registra a utilização do cupom
    update public.cupom
    set quantidade_usada = quantidade_usada + 1
    where codigo = p_codigo;

    return v_desconto;
end;
$$;


ALTER FUNCTION "public"."aplicar_cupom"("p_codigo" character varying, "p_valor_compra" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."aplicar_cupom_pedido"("p_id_pedido" bigint, "p_codigo" character varying) RETURNS numeric
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
    v_pedido public.pedido%rowtype;
    v_cupom public.cupom%rowtype;
    v_desconto numeric;
    v_total numeric;
    v_nivel_assinante character varying;
    v_base_elegivel numeric;
BEGIN

    -- Localiza e bloqueia o pedido durante a operação
    SELECT *
    INTO v_pedido
    FROM public.pedido
    WHERE id_pedido = p_id_pedido
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pedido não encontrado.';
    END IF;

    -- Localiza o cupom
    SELECT *
    INTO v_cupom
    FROM public.cupom
    WHERE codigo = p_codigo;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cupom não encontrado.';
    END IF;


    -- ========================================================
    -- RF044
    -- Cupom exclusivo exige assinatura ativa
    -- ========================================================

    IF v_cupom.exclusivo_assinante = true THEN

        v_nivel_assinante :=
            public.obter_nivel_assinante(v_pedido.id_usuario);

        IF v_nivel_assinante IS NULL THEN
            RAISE EXCEPTION
                'Este cupom é exclusivo para assinantes ativos.';
        END IF;

    END IF;


    -- Impede reaplicação do mesmo cupom no mesmo pedido
    IF v_pedido.id_cupom = v_cupom.id_cupom THEN
        RAISE EXCEPTION
            'Cupom já aplicado a este pedido.';
    END IF;

    -- Impede substituição de um cupom já aplicado por outro
    IF v_pedido.id_cupom IS NOT NULL THEN
        RAISE EXCEPTION
            'Este pedido já possui um cupom aplicado.';
    END IF;


    -- ========================================================
    -- RF050
    -- Calcula a parcela do pedido elegível ao cupom.
    --
    -- Sem restrições:
    --     base = subtotal completo
    --
    -- Com restrições:
    --     base = somente produtos/categorias elegíveis
    -- ========================================================

    v_base_elegivel :=
        public.calcular_base_elegivel_cupom(
            p_id_pedido,
            v_cupom.id_cupom
        );

    IF v_base_elegivel <= 0 THEN
        RAISE EXCEPTION
            'Nenhum item do pedido é elegível para este cupom.';
    END IF;


    -- Valida o cupom e calcula o desconto utilizando
    -- exclusivamente a base elegível da RF050.
    v_desconto := public.aplicar_cupom(
        p_codigo,
        v_base_elegivel
    );

    IF v_desconto <= 0 THEN
        RAISE EXCEPTION
            'Cupom inválido ou não aplicável.';
    END IF;


    -- Calcula o novo total.
    -- O desconto incide sobre a base elegível,
    -- mas é abatido do total completo do pedido.
    v_total := greatest(
        v_pedido.subtotal
        + v_pedido.valor_frete
        - v_desconto,
        0
    );


    -- Atualiza o pedido
    UPDATE public.pedido
    SET
        id_cupom = v_cupom.id_cupom,
        valor_desconto = v_desconto,
        valor_total = v_total,
        data_atualizacao = now()
    WHERE id_pedido = p_id_pedido;


    RETURN v_total;

END;
$$;


ALTER FUNCTION "public"."aplicar_cupom_pedido"("p_id_pedido" bigint, "p_codigo" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."atualizar_data_atualizacao"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
    new.data_atualizacao := now();
    return new;
end;
$$;


ALTER FUNCTION "public"."atualizar_data_atualizacao"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."atualizar_data_carrinho"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
    v_id_carrinho bigint;
begin

    v_id_carrinho := coalesce(new.id_carrinho, old.id_carrinho);

    update public.carrinho
    set data_atualizacao = now()
    where id_carrinho = v_id_carrinho;

    return coalesce(new, old);
end;
$$;


ALTER FUNCTION "public"."atualizar_data_carrinho"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."atualizar_data_rastreamento"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
    NEW.data_atualizacao := now();

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."atualizar_data_rastreamento"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."atualizar_estoque_admin"("p_id_produto" bigint, "p_quantidade" integer, "p_estoque_minimo" integer) RETURNS TABLE("id_produto" bigint, "quantidade" integer, "estoque_minimo" integer, "data_atualizacao" timestamp with time zone)
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN

    -- --------------------------------------------------------
    -- 1. Verifica se o usuário autenticado é administrador
    -- --------------------------------------------------------
    IF NOT public.eh_admin() THEN
        RAISE EXCEPTION
            'Acesso negado. Apenas administradores podem alterar o estoque.';
    END IF;

    -- --------------------------------------------------------
    -- 2. Valida os parâmetros
    -- --------------------------------------------------------
    IF p_id_produto IS NULL THEN
        RAISE EXCEPTION 'Produto não informado.';
    END IF;

    IF p_quantidade IS NULL OR p_quantidade < 0 THEN
        RAISE EXCEPTION
            'A quantidade do estoque deve ser maior ou igual a zero.';
    END IF;

    IF p_estoque_minimo IS NULL OR p_estoque_minimo < 0 THEN
        RAISE EXCEPTION
            'O estoque mínimo deve ser maior ou igual a zero.';
    END IF;

    -- --------------------------------------------------------
    -- 3. Confirma a existência do produto
    -- --------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1
        FROM public.produto p
        WHERE p.id_produto = p_id_produto
    ) THEN
        RAISE EXCEPTION
            'Produto % não encontrado.',
            p_id_produto;
    END IF;

    -- --------------------------------------------------------
    -- 4. Atualiza o estoque
    -- A política RLS da tabela estoque continua sendo aplicada
    -- --------------------------------------------------------
    UPDATE public.estoque e
       SET quantidade = p_quantidade,
           estoque_minimo = p_estoque_minimo
     WHERE e.id_produto = p_id_produto;

    -- --------------------------------------------------------
    -- 5. Garante que exista registro de estoque para o produto
    -- --------------------------------------------------------
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Registro de estoque não encontrado para o produto %.',
            p_id_produto;
    END IF;

    -- --------------------------------------------------------
    -- 6. Retorna o estado final
    -- --------------------------------------------------------
    RETURN QUERY
    SELECT
        e.id_produto,
        e.quantidade,
        e.estoque_minimo,
        e.data_atualizacao
    FROM public.estoque e
    WHERE e.id_produto = p_id_produto;

END;
$$;


ALTER FUNCTION "public"."atualizar_estoque_admin"("p_id_produto" bigint, "p_quantidade" integer, "p_estoque_minimo" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."atualizar_status_pagamento"("p_id_pagamento" bigint, "p_novo_status" character varying) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
    v_id_pedido bigint;
    v_status_atual varchar;
    v_status_pedido varchar;
BEGIN
    -- Validar o novo status.
    IF p_novo_status IS NULL
       OR p_novo_status NOT IN (
           'pendente', 'aprovado',
           'recusado', 'cancelado'
       )
    THEN
        RAISE EXCEPTION
            'Status de pagamento inválido: %',
            p_novo_status;
    END IF;

    -- Bloquear o pagamento durante a atualização.
    SELECT id_pedido, status
    INTO v_id_pedido, v_status_atual
    FROM public.pagamento
    WHERE id_pagamento = p_id_pagamento
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Pagamento % não encontrado.',
            p_id_pagamento;
    END IF;

    -- Repetir o mesmo status não gera alteração.
    IF v_status_atual = p_novo_status THEN
        RETURN;
    END IF;

    -- Apenas pagamentos pendentes podem mudar.
    IF v_status_atual <> 'pendente' THEN
        RAISE EXCEPTION
            'Transição de pagamento não permitida: % -> %',
            v_status_atual, p_novo_status;
    END IF;

    -- Não permitir retorno ao status pendente.
    IF p_novo_status = 'pendente' THEN
        RAISE EXCEPTION
            'Transição de pagamento não permitida.';
    END IF;

    -- Validar o pedido relacionado.
    SELECT status
    INTO v_status_pedido
    FROM public.pedido
    WHERE id_pedido = v_id_pedido
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Pedido % não encontrado.',
            v_id_pedido;
    END IF;

    IF v_status_pedido <> 'aguardando_pagamento' THEN
        RAISE EXCEPTION
            'Pedido % não permite atualização de pagamento. Status: %',
            v_id_pedido, v_status_pedido;
    END IF;

    -- Atualizar pagamento.
    UPDATE public.pagamento
    SET status = p_novo_status,
        data_atualizacao = now()
    WHERE id_pagamento = p_id_pagamento;

    -- Pagamento aprovado confirma o pedido.
    IF p_novo_status = 'aprovado' THEN
        UPDATE public.pedido
        SET status = 'pago',
            data_atualizacao = now()
        WHERE id_pedido = v_id_pedido;
    END IF;
END;
$$;


ALTER FUNCTION "public"."atualizar_status_pagamento"("p_id_pagamento" bigint, "p_novo_status" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."atualizar_status_pedido_admin"("p_id_pedido" bigint, "p_novo_status" character varying) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
    v_status_atual character varying;
BEGIN
    -- --------------------------------------------------------
    -- 1. Somente administrador
    -- --------------------------------------------------------
    IF NOT public.eh_admin() THEN
        RAISE EXCEPTION 'Apenas administradores podem alterar o status do pedido.'
            USING ERRCODE = '42501';
    END IF;

    -- --------------------------------------------------------
    -- 2. Obtém e bloqueia o pedido durante a operação
    -- --------------------------------------------------------
    SELECT p.status
      INTO v_status_atual
      FROM public.pedido p
     WHERE p.id_pedido = p_id_pedido
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pedido % não encontrado.', p_id_pedido
            USING ERRCODE = 'P0002';
    END IF;

    -- --------------------------------------------------------
    -- 3. Nenhuma alteração necessária
    -- --------------------------------------------------------
    IF v_status_atual = p_novo_status THEN
        RETURN;
    END IF;

    -- --------------------------------------------------------
    -- 4. Pago é definido exclusivamente pelo fluxo de pagamento
    -- --------------------------------------------------------
    IF p_novo_status = 'pago' THEN
        RAISE EXCEPTION
            'O status pago deve ser definido pelo fluxo de pagamento.';
    END IF;

    -- --------------------------------------------------------
    -- 5. Valida as transições administrativas
    -- --------------------------------------------------------
    IF NOT (
           (v_status_atual = 'aguardando_pagamento'
                AND p_novo_status = 'cancelado')

        OR (v_status_atual = 'pago'
                AND p_novo_status IN ('em_preparacao', 'cancelado'))

        OR (v_status_atual = 'em_preparacao'
                AND p_novo_status IN ('enviado', 'cancelado'))

        OR (v_status_atual = 'enviado'
                AND p_novo_status IN ('entregue', 'cancelado'))
    ) THEN
        RAISE EXCEPTION
            'Transição de status inválida: % -> %.',
            v_status_atual,
            p_novo_status
            USING ERRCODE = '23514';
    END IF;

    -- --------------------------------------------------------
    -- 6. Atualiza o pedido
    --
    -- O trigger trg_registrar_historico_status_pedido
    -- registrará a alteração automaticamente.
    -- --------------------------------------------------------
    UPDATE public.pedido
       SET status = p_novo_status,
           data_atualizacao = now()
     WHERE id_pedido = p_id_pedido;

END;
$$;


ALTER FUNCTION "public"."atualizar_status_pedido_admin"("p_id_pedido" bigint, "p_novo_status" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calcular_base_elegivel_cupom"("p_id_pedido" bigint, "p_id_cupom" bigint) RETURNS numeric
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
    v_subtotal_pedido numeric;
    v_possui_produto boolean;
    v_possui_categoria boolean;
    v_base_elegivel numeric;
BEGIN
    -- --------------------------------------------------------
    -- 1. Confirma a existência do pedido e obtém seu subtotal
    -- --------------------------------------------------------
    SELECT p.subtotal
      INTO v_subtotal_pedido
    FROM public.pedido p
    WHERE p.id_pedido = p_id_pedido;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pedido não encontrado.';
    END IF;

    -- --------------------------------------------------------
    -- 2. Confirma a existência do cupom
    -- --------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1
        FROM public.cupom c
        WHERE c.id_cupom = p_id_cupom
    ) THEN
        RAISE EXCEPTION 'Cupom não encontrado.';
    END IF;

    -- --------------------------------------------------------
    -- 3. Verifica se o cupom possui restrições
    -- --------------------------------------------------------
    SELECT EXISTS (
        SELECT 1
        FROM public.cupom_produto cp
        WHERE cp.id_cupom = p_id_cupom
    )
    INTO v_possui_produto;

    SELECT EXISTS (
        SELECT 1
        FROM public.cupom_categoria cc
        WHERE cc.id_cupom = p_id_cupom
    )
    INTO v_possui_categoria;

    -- --------------------------------------------------------
    -- 4. Cupom geral:
    --    sem produto e sem categoria associados
    -- --------------------------------------------------------
    IF NOT v_possui_produto
       AND NOT v_possui_categoria THEN

        RETURN COALESCE(v_subtotal_pedido, 0)::numeric;

    END IF;

    -- --------------------------------------------------------
    -- 5. Cupom restrito:
    --    soma cada item do pedido apenas uma vez.
    --
    --    O item é elegível quando:
    --    - seu produto estiver associado ao cupom; OU
    --    - sua categoria estiver associada ao cupom.
    --
    --    O uso de OR evita dupla contabilização.
    -- --------------------------------------------------------
    SELECT COALESCE(
        SUM(ip.subtotal),
        0
    )
    INTO v_base_elegivel

    FROM public.item_pedido ip

    JOIN public.produto pr
      ON pr.id_produto = ip.id_produto

    WHERE ip.id_pedido = p_id_pedido

      AND (
            (
                v_possui_produto
                AND EXISTS (
                    SELECT 1
                    FROM public.cupom_produto cp
                    WHERE cp.id_cupom = p_id_cupom
                      AND cp.id_produto = ip.id_produto
                )
            )

            OR

            (
                v_possui_categoria
                AND EXISTS (
                    SELECT 1
                    FROM public.cupom_categoria cc
                    WHERE cc.id_cupom = p_id_cupom
                      AND cc.id_categoria = pr.id_categoria
                )
            )
          );

    RETURN COALESCE(v_base_elegivel, 0)::numeric;
END;
$$;


ALTER FUNCTION "public"."calcular_base_elegivel_cupom"("p_id_pedido" bigint, "p_id_cupom" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calcular_desconto_cupom"("p_codigo" character varying, "p_valor_compra" numeric) RETURNS numeric
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
    v_cupom public.cupom%rowtype;
    v_desconto numeric;
begin
    -- Valida o cupom antes de calcular o desconto
    if not public.validar_cupom(p_codigo, p_valor_compra) then
        return 0;
    end if;

    select *
      into v_cupom
      from public.cupom
     where codigo = p_codigo;

    -- Calcula conforme o tipo de desconto
    if v_cupom.tipo_desconto = 'percentual' then
        v_desconto :=
            p_valor_compra * (v_cupom.valor_desconto / 100);

    elsif v_cupom.tipo_desconto = 'fixo' then
        v_desconto := v_cupom.valor_desconto;

    else
        return 0;
    end if;

    -- Impede que o desconto ultrapasse o valor da compra
    return least(v_desconto, p_valor_compra);
end;
$$;


ALTER FUNCTION "public"."calcular_desconto_cupom"("p_codigo" character varying, "p_valor_compra" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancelar_assinatura"("p_id_assinatura" bigint) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_usuario uuid;
BEGIN
    v_usuario := auth.uid();

    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'Usuário não autenticado';
    END IF;

    UPDATE public.assinatura
    SET
        status = 'CANCELADA',
        renovacao_automatica = false,
        data_cancelamento = CURRENT_DATE,
        data_atualizacao = now()
    WHERE id_assinatura = p_id_assinatura
      AND id_usuario = v_usuario
      AND status IN ('ATIVA', 'PAUSADA');

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Assinatura não encontrada ou cancelamento não permitido';
    END IF;

    RETURN true;
END;
$$;


ALTER FUNCTION "public"."cancelar_assinatura"("p_id_assinatura" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."contratar_assinatura"("p_id_plano" bigint) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_usuario uuid;
    v_plano record;
    v_id_assinatura bigint;
BEGIN
    v_usuario := auth.uid();

    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'Usuário não autenticado.';
    END IF;

    IF p_id_plano IS NULL THEN
        RAISE EXCEPTION 'Informe um plano válido.';
    END IF;

    -- Impedir contratações simultâneas para o mesmo usuário.
    -- O bloqueio também serializa tentativas concorrentes.
    PERFORM 1
    FROM public.perfil
    WHERE id_usuario = v_usuario
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Perfil do usuário não encontrado.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.assinatura
        WHERE id_usuario = v_usuario
          AND status IN ('PENDENTE', 'ATIVA', 'PAUSADA')
    ) THEN
        RAISE EXCEPTION
            'Já existe uma assinatura pendente, ativa ou pausada para este usuário.';
    END IF;

    -- Consultar exclusivamente o catálogo oficial.
    SELECT
        id_plano,
        nome_plano,
        periodicidade,
        valor
    INTO v_plano
    FROM public.plano_assinatura
    WHERE id_plano = p_id_plano
      AND ativo = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Plano inexistente ou indisponível.';
    END IF;

    -- Criar assinatura sem ativação antecipada.
    INSERT INTO public.assinatura (
        id_usuario,
        id_plano,
        nome_plano,
        periodicidade,
        valor,
        status,
        data_inicio,
        data_proxima_cobranca,
        data_cancelamento,
        renovacao_automatica
    )
    VALUES (
        v_usuario,
        v_plano.id_plano,
        v_plano.nome_plano,
        v_plano.periodicidade,
        v_plano.valor,
        'PENDENTE',
        CURRENT_DATE,
        NULL,
        NULL,
        true
    )
    RETURNING id_assinatura INTO v_id_assinatura;

    RETURN v_id_assinatura;
END;
$$;


ALTER FUNCTION "public"."contratar_assinatura"("p_id_plano" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."criar_notificacao_assinante"("p_id_usuario" "uuid", "p_tipo" character varying, "p_titulo" character varying, "p_mensagem" "text", "p_nivel_minimo" character varying DEFAULT NULL::character varying) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_id_notificacao bigint;
    v_nivel_usuario character varying;
    v_peso_usuario integer;
    v_peso_minimo integer;
BEGIN
    -- Confirma a existência do usuário
    IF NOT EXISTS (
        SELECT 1
        FROM public.perfil p
        WHERE p.id_usuario = p_id_usuario
    ) THEN
        RAISE EXCEPTION 'Usuário não encontrado.';
    END IF;

    -- Valida o tipo antes da gravação
    IF p_tipo IS NULL
       OR p_tipo NOT IN (
            'IDENTIFICACAO',
            'VANTAGEM',
            'NOVIDADE',
            'LANCAMENTO'
       )
    THEN
        RAISE EXCEPTION 'Tipo de notificação inválido.';
    END IF;

    -- Valida o nível informado
    IF p_nivel_minimo IS NOT NULL
       AND p_nivel_minimo NOT IN (
            'INICIANTE',
            'APRECIADOR',
            'ESPECIALISTA'
       )
    THEN
        RAISE EXCEPTION 'Nível mínimo de assinatura inválido.';
    END IF;

    -- Quando existe nível mínimo, verifica a assinatura do usuário
    IF p_nivel_minimo IS NOT NULL THEN

        v_nivel_usuario :=
            public.obter_nivel_assinante(p_id_usuario);

        IF v_nivel_usuario IS NULL THEN
            RAISE EXCEPTION
                'Usuário não possui assinatura ativa.';
        END IF;

        v_peso_usuario :=
            CASE v_nivel_usuario
                WHEN 'INICIANTE' THEN 1
                WHEN 'APRECIADOR' THEN 2
                WHEN 'ESPECIALISTA' THEN 3
                ELSE 0
            END;

        v_peso_minimo :=
            CASE p_nivel_minimo
                WHEN 'INICIANTE' THEN 1
                WHEN 'APRECIADOR' THEN 2
                WHEN 'ESPECIALISTA' THEN 3
                ELSE 0
            END;

        IF v_peso_usuario < v_peso_minimo THEN
            RAISE EXCEPTION
                'Nível de assinatura insuficiente para esta notificação.';
        END IF;
    END IF;

    -- Registra a notificação
    INSERT INTO public.notificacao_assinante (
        id_usuario,
        tipo,
        titulo,
        mensagem,
        nivel_minimo
    )
    VALUES (
        p_id_usuario,
        p_tipo,
        p_titulo,
        p_mensagem,
        p_nivel_minimo
    )
    RETURNING id_notificacao
    INTO v_id_notificacao;

    RETURN v_id_notificacao;
END;
$$;


ALTER FUNCTION "public"."criar_notificacao_assinante"("p_id_usuario" "uuid", "p_tipo" character varying, "p_titulo" character varying, "p_mensagem" "text", "p_nivel_minimo" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."criar_pedido"("p_id_carrinho" bigint, "p_id_endereco" bigint) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_id_usuario uuid;
    v_id_pedido bigint;
    v_subtotal numeric(10,2);
    v_valido boolean;
    v_mensagem text;
BEGIN
    -- Exige identidade autenticada.
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario nao autenticado.';
    END IF;

    -- Valida propriedade, status e estoque do carrinho.
    SELECT valido, mensagem
    INTO v_valido, v_mensagem
    FROM public.validar_carrinho_checkout(p_id_carrinho);

    IF v_valido IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            '%',
            COALESCE(v_mensagem, 'Carrinho invalido.');
    END IF;

    SELECT c.id_usuario
    INTO v_id_usuario
    FROM public.carrinho c
    WHERE c.id_carrinho = p_id_carrinho;

    -- Defesa adicional para SECURITY DEFINER.
    IF v_id_usuario IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION
            'Carrinho nao pertence ao usuario autenticado.';
    END IF;

    -- Endereco obrigatoriamente do mesmo cliente.
    IF NOT EXISTS (
        SELECT 1
        FROM public.endereco e
        WHERE e.id_endereco = p_id_endereco
          AND e.id_usuario = auth.uid()
          AND e.ativo = true
    ) THEN
        RAISE EXCEPTION
            'Endereco invalido ou nao pertence ao usuario.';
    END IF;

    -- RF030: recuperar checkout interrompido.
    SELECT p.id_pedido
    INTO v_id_pedido
    FROM public.pedido p
    WHERE p.id_carrinho = p_id_carrinho
      AND p.id_usuario = auth.uid()
      AND p.status = 'aguardando_pagamento'
      AND NOT EXISTS (
          SELECT 1
          FROM public.pagamento pg
          WHERE pg.id_pedido = p.id_pedido
      )
    ORDER BY
        p.data_atualizacao DESC,
        p.data_criacao DESC,
        p.id_pedido DESC
    LIMIT 1;

    IF v_id_pedido IS NOT NULL THEN
        RETURN v_id_pedido;
    END IF;

    -- Calcular subtotal dos itens.
    SELECT COALESCE(
        SUM(ic.quantidade * ic.preco_unitario),
        0
    )::numeric(10,2)
    INTO v_subtotal
    FROM public.item_carrinho ic
    WHERE ic.id_carrinho = p_id_carrinho;

    IF v_subtotal <= 0 THEN
        RAISE EXCEPTION 'Subtotal invalido.';
    END IF;

    -- Criar pedido.
    INSERT INTO public.pedido (
        id_usuario,
        id_carrinho,
        id_endereco,
        status,
        subtotal,
        valor_frete,
        valor_desconto,
        valor_total
    )
    VALUES (
        auth.uid(),
        p_id_carrinho,
        p_id_endereco,
        'aguardando_pagamento',
        v_subtotal,
        0.00,
        0.00,
        v_subtotal
    )
    RETURNING id_pedido INTO v_id_pedido;

    -- Copiar itens do carrinho.
    INSERT INTO public.item_pedido (
        id_pedido,
        id_produto,
        quantidade,
        preco_unitario,
        subtotal
    )
    SELECT
        v_id_pedido,
        ic.id_produto,
        ic.quantidade,
        ic.preco_unitario,
        (ic.quantidade * ic.preco_unitario)::numeric(10,2)
    FROM public.item_carrinho ic
    WHERE ic.id_carrinho = p_id_carrinho;

    RETURN v_id_pedido;
END;
$$;


ALTER FUNCTION "public"."criar_pedido"("p_id_carrinho" bigint, "p_id_endereco" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."criar_perfil_novo_usuario"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
    insert into public.perfil (
        id_usuario,
        nome,
        tipo_usuario
    )
    values (
        new.id,
        coalesce(
            new.raw_user_meta_data ->> 'nome',
            split_part(new.email, '@', 1)
        ),
        'CLIENTE'
    );

    return new;
end;
$$;


ALTER FUNCTION "public"."criar_perfil_novo_usuario"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dashboard_produtos_mais_vendidos"("p_limite" integer DEFAULT 10) RETURNS TABLE("id_produto" bigint, "nome_produto" "text", "quantidade_vendida" bigint, "valor_vendido" numeric)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$

    SELECT
        v.id_produto,
        v.produto::text AS nome_produto,
        SUM(v.quantidade)::bigint AS quantidade_vendida,
        COALESCE(
            SUM(v.valor_item),
            0
        )::numeric(14,2) AS valor_vendido

    FROM public.vw_vendas_detalhadas v

    GROUP BY
        v.id_produto,
        v.produto

    ORDER BY
        quantidade_vendida DESC,
        valor_vendido DESC,
        v.id_produto

    LIMIT GREATEST(COALESCE(p_limite, 10), 1);

$$;


ALTER FUNCTION "public"."dashboard_produtos_mais_vendidos"("p_limite" integer) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."categoria" (
    "id_categoria" bigint NOT NULL,
    "nome" character varying(100) NOT NULL,
    "descricao" "text",
    "ativo" boolean DEFAULT true NOT NULL,
    "data_cadastro" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."categoria" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."item_pedido" (
    "id_item_pedido" bigint NOT NULL,
    "id_pedido" bigint NOT NULL,
    "id_produto" bigint NOT NULL,
    "quantidade" integer NOT NULL,
    "preco_unitario" numeric(10,2) NOT NULL,
    "subtotal" numeric(10,2) NOT NULL,
    "data_criacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_item_pedido_preco" CHECK (("preco_unitario" >= (0)::numeric)),
    CONSTRAINT "chk_item_pedido_quantidade" CHECK (("quantidade" > 0)),
    CONSTRAINT "chk_item_pedido_subtotal" CHECK (("subtotal" >= (0)::numeric))
);


ALTER TABLE "public"."item_pedido" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pagamento" (
    "id_pagamento" bigint NOT NULL,
    "id_pedido" bigint NOT NULL,
    "metodo" character varying(20) NOT NULL,
    "status" character varying(30) DEFAULT 'pendente'::character varying NOT NULL,
    "valor" numeric(10,2) NOT NULL,
    "id_transacao" character varying(100),
    "data_criacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_pagamento_metodo" CHECK ((("metodo")::"text" = ANY (ARRAY[('pix'::character varying)::"text", ('cartao'::character varying)::"text", ('boleto'::character varying)::"text"]))),
    CONSTRAINT "chk_pagamento_status" CHECK ((("status")::"text" = ANY (ARRAY[('pendente'::character varying)::"text", ('aprovado'::character varying)::"text", ('recusado'::character varying)::"text", ('cancelado'::character varying)::"text"]))),
    CONSTRAINT "chk_pagamento_valor" CHECK (("valor" >= (0)::numeric))
);


ALTER TABLE "public"."pagamento" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pedido" (
    "id_pedido" bigint NOT NULL,
    "id_usuario" "uuid" NOT NULL,
    "id_carrinho" bigint NOT NULL,
    "id_endereco" bigint NOT NULL,
    "status" character varying(30) DEFAULT 'aguardando_pagamento'::character varying NOT NULL,
    "subtotal" numeric(10,2) NOT NULL,
    "valor_frete" numeric(10,2) DEFAULT 0 NOT NULL,
    "valor_desconto" numeric(10,2) DEFAULT 0 NOT NULL,
    "valor_total" numeric(10,2) NOT NULL,
    "data_criacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id_cupom" bigint,
    CONSTRAINT "chk_pedido_desconto" CHECK (("valor_desconto" >= (0)::numeric)),
    CONSTRAINT "chk_pedido_frete" CHECK (("valor_frete" >= (0)::numeric)),
    CONSTRAINT "chk_pedido_status" CHECK ((("status")::"text" = ANY (ARRAY[('aguardando_pagamento'::character varying)::"text", ('pago'::character varying)::"text", ('em_preparacao'::character varying)::"text", ('enviado'::character varying)::"text", ('entregue'::character varying)::"text", ('cancelado'::character varying)::"text"]))),
    CONSTRAINT "chk_pedido_subtotal" CHECK (("subtotal" >= (0)::numeric)),
    CONSTRAINT "chk_pedido_total" CHECK (("valor_total" >= (0)::numeric))
);


ALTER TABLE "public"."pedido" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."produto" (
    "id_produto" bigint NOT NULL,
    "id_categoria" bigint NOT NULL,
    "nome" character varying(150) NOT NULL,
    "descricao" "text",
    "preco" numeric NOT NULL,
    "sku" character varying(50) NOT NULL,
    "imagem_principal" "text",
    "peso" numeric,
    "ativo" boolean DEFAULT true NOT NULL,
    "destaque" boolean DEFAULT false NOT NULL,
    "data_cadastro" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_produto_peso" CHECK ((("peso" IS NULL) OR (("peso")::double precision >= ((0)::numeric)::double precision))),
    CONSTRAINT "chk_produto_preco" CHECK ((("preco")::double precision >= ((0)::numeric)::double precision))
);


ALTER TABLE "public"."produto" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_vendas_detalhadas" WITH ("security_invoker"='true') AS
 SELECT "p"."id_pedido",
    "p"."id_usuario",
    "pg"."id_pagamento",
    "pg"."metodo" AS "metodo_pagamento",
    "pg"."status" AS "status_pagamento",
    "pg"."data_atualizacao" AS "data_venda",
    "ip"."id_item_pedido",
    "ip"."id_produto",
    "pr"."nome" AS "produto",
    "pr"."sku",
    "c"."id_categoria",
    "c"."nome" AS "categoria",
    "ip"."quantidade",
    "ip"."preco_unitario",
    "ip"."subtotal" AS "valor_item",
    "p"."subtotal" AS "subtotal_pedido",
    "p"."valor_frete",
    "p"."valor_desconto",
    "p"."valor_total"
   FROM (((("public"."pedido" "p"
     JOIN "public"."pagamento" "pg" ON (("pg"."id_pedido" = "p"."id_pedido")))
     JOIN "public"."item_pedido" "ip" ON (("ip"."id_pedido" = "p"."id_pedido")))
     JOIN "public"."produto" "pr" ON (("pr"."id_produto" = "ip"."id_produto")))
     JOIN "public"."categoria" "c" ON (("c"."id_categoria" = "pr"."id_categoria")))
  WHERE ((("p"."status")::"text" = 'pago'::"text") AND (("pg"."status")::"text" = 'aprovado'::"text"));


ALTER VIEW "public"."vw_vendas_detalhadas" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dashboard_vendas_exportacao"("p_data_inicio" "date" DEFAULT NULL::"date", "p_data_fim" "date" DEFAULT NULL::"date", "p_id_produto" bigint DEFAULT NULL::bigint, "p_categoria" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."vw_vendas_detalhadas"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$

    SELECT *
    FROM public.dashboard_vendas_filtradas(
        p_data_inicio,
        p_data_fim,
        p_id_produto,
        p_categoria
    );

$$;


ALTER FUNCTION "public"."dashboard_vendas_exportacao"("p_data_inicio" "date", "p_data_fim" "date", "p_id_produto" bigint, "p_categoria" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dashboard_vendas_filtradas"("p_data_inicio" "date" DEFAULT NULL::"date", "p_data_fim" "date" DEFAULT NULL::"date", "p_id_produto" bigint DEFAULT NULL::bigint, "p_categoria" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."vw_vendas_detalhadas"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$

    SELECT v.*
    FROM public.vw_vendas_detalhadas v
    WHERE
        (p_data_inicio IS NULL OR v.data_venda::date >= p_data_inicio)
        AND
        (p_data_fim IS NULL OR v.data_venda::date <= p_data_fim)
        AND
        (p_id_produto IS NULL OR v.id_produto = p_id_produto)
        AND
        (p_categoria IS NULL OR v.categoria = p_categoria)
    ORDER BY
        v.data_venda DESC,
        v.id_pedido DESC,
        v.id_produto;

$$;


ALTER FUNCTION "public"."dashboard_vendas_filtradas"("p_data_inicio" "date", "p_data_fim" "date", "p_id_produto" bigint, "p_categoria" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dashboard_vendas_kpis"("p_data_inicial" "date" DEFAULT NULL::"date", "p_data_final" "date" DEFAULT NULL::"date") RETURNS TABLE("total_vendas" numeric, "quantidade_pedidos" bigint, "quantidade_itens" bigint, "ticket_medio" numeric)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$

    WITH vendas AS (
        SELECT
            v.id_pedido,
            v.quantidade,
            v.valor_total
        FROM public.vw_vendas_detalhadas v
        WHERE
            (p_data_inicial IS NULL
                OR v.data_venda >= p_data_inicial::timestamptz)
        AND
            (p_data_final IS NULL
                OR v.data_venda < (p_data_final + 1)::timestamptz)
    ),

    pedidos AS (
        SELECT DISTINCT
            id_pedido,
            valor_total
        FROM vendas
    )

    SELECT
        COALESCE(SUM(p.valor_total), 0)::numeric(14,2)
            AS total_vendas,

        COUNT(*)::bigint
            AS quantidade_pedidos,

        COALESCE(
            (SELECT SUM(v.quantidade) FROM vendas v),
            0
        )::bigint
            AS quantidade_itens,

        COALESCE(
            AVG(p.valor_total),
            0
        )::numeric(14,2)
            AS ticket_medio

    FROM pedidos p;

$$;


ALTER FUNCTION "public"."dashboard_vendas_kpis"("p_data_inicial" "date", "p_data_final" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."definir_preco_oficial_carrinho"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
    v_preco numeric;
BEGIN
    SELECT p.preco
    INTO v_preco
    FROM public.produto p
    WHERE p.id_produto = NEW.id_produto;

    IF NOT FOUND OR v_preco IS NULL THEN
        RAISE EXCEPTION
            'Produto sem preco valido no catalogo.';
    END IF;

    NEW.preco_unitario := v_preco;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."definir_preco_oficial_carrinho"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."desativar_renovacao_assinatura"("p_id_assinatura" bigint) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_usuario uuid;
BEGIN
    v_usuario := auth.uid();

    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'Usuário não autenticado';
    END IF;

    UPDATE public.assinatura
    SET
        renovacao_automatica = false,
        data_atualizacao = now()
    WHERE id_assinatura = p_id_assinatura
      AND id_usuario = v_usuario
      AND status IN ('ATIVA', 'PAUSADA');

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Assinatura não encontrada ou alteração não permitida';
    END IF;

    RETURN true;
END;
$$;


ALTER FUNCTION "public"."desativar_renovacao_assinatura"("p_id_assinatura" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."eh_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
    select exists (
        select 1
        from public.perfil p
        where p.id_usuario = auth.uid()
          and p.tipo_usuario = 'ADMIN'
          and p.ativo = true
    );
$$;


ALTER FUNCTION "public"."eh_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."limpar_carrinho"("p_id_carrinho" bigint) RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
    v_itens_removidos integer;
begin
    delete from public.item_carrinho
    where id_carrinho = p_id_carrinho;

    get diagnostics v_itens_removidos = row_count;

    return v_itens_removidos;
end;
$$;


ALTER FUNCTION "public"."limpar_carrinho"("p_id_carrinho" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."listar_clientes_admin"() RETURNS TABLE("id_usuario" "uuid", "nome" character varying, "email" character varying, "localizacao" "text", "tipo_cliente" "text", "ativo" boolean, "data_cadastro" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN

    -- Segurança: somente administradores podem executar a operação
    IF NOT public.eh_admin() THEN
        RAISE EXCEPTION 'Acesso negado. Operação permitida somente para administradores.';
    END IF;

    RETURN QUERY

    WITH pedidos AS (
        SELECT
            p.id_usuario,
            COUNT(*) FILTER (
                WHERE p.status <> 'cancelado'
            ) AS pedidos_validos
        FROM public.pedido p
        GROUP BY p.id_usuario
    ),

    assinaturas AS (
        SELECT
            a.id_usuario,
            COUNT(*) FILTER (
                WHERE a.status = 'ATIVA'
            ) AS assinaturas_ativas
        FROM public.assinatura a
        GROUP BY a.id_usuario
    )

    SELECT
        pf.id_usuario,
        pf.nome,
        u.email,

        CASE
            WHEN e.id_endereco IS NOT NULL
                THEN e.cidade || '/' || e.estado
            ELSE NULL
        END::text AS localizacao,

        CASE
            WHEN COALESCE(a.assinaturas_ativas, 0) > 0
                THEN 'ASSINANTE'

            WHEN COALESCE(pd.pedidos_validos, 0) >= 2
                THEN 'RECORRENTE'

            ELSE 'NOVO'
        END::text AS tipo_cliente,

        pf.ativo,
        pf.data_cadastro

    FROM public.perfil pf

    JOIN auth.users u
        ON u.id = pf.id_usuario

    LEFT JOIN public.endereco e
        ON e.id_usuario = pf.id_usuario
       AND e.principal = true
       AND e.ativo = true

    LEFT JOIN pedidos pd
        ON pd.id_usuario = pf.id_usuario

    LEFT JOIN assinaturas a
        ON a.id_usuario = pf.id_usuario

    WHERE pf.tipo_usuario = 'CLIENTE'

    ORDER BY pf.nome;

END;
$$;


ALTER FUNCTION "public"."listar_clientes_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."obter_beneficios_assinante"("p_id_usuario" "uuid") RETURNS TABLE("id_beneficio" bigint, "nivel" character varying, "nome" character varying, "descricao" "text", "ordem_exibicao" integer)
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
    v_nivel character varying;
BEGIN
    -- Identifica o nível atual do assinante
    v_nivel := public.obter_nivel_assinante(p_id_usuario);

    -- Usuário sem assinatura ativa não recebe benefícios
    IF v_nivel IS NULL THEN
        RETURN;
    END IF;

    -- Retorna apenas os benefícios ativos do nível identificado
    RETURN QUERY
    SELECT
        b.id_beneficio,
        b.nivel,
        b.nome,
        b.descricao,
        b.ordem_exibicao
    FROM public.beneficio_assinatura b
    WHERE b.nivel = v_nivel
      AND b.ativo = true
    ORDER BY b.ordem_exibicao, b.id_beneficio;
END;
$$;


ALTER FUNCTION "public"."obter_beneficios_assinante"("p_id_usuario" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."obter_nivel_assinante"("p_id_usuario" "uuid") RETURNS character varying
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$

    SELECT a.nome_plano
    FROM public.assinatura a
    WHERE a.id_usuario = p_id_usuario
      AND a.status = 'ATIVA'
      AND (
            a.data_cancelamento IS NULL
            OR a.data_cancelamento > CURRENT_DATE
          )
    LIMIT 1;

$$;


ALTER FUNCTION "public"."obter_nivel_assinante"("p_id_usuario" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."obter_ou_criar_carrinho"("p_id_usuario" "uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_id_carrinho bigint;
    v_role text;
    v_auth_uid uuid;
BEGIN

    -- Contexto da chamada
    v_role := COALESCE(
        current_setting('request.jwt.claim.role', true),
        current_user
    );

    v_auth_uid := auth.uid();


    -- ========================================================
    -- CONTROLE DE ACESSO
    -- ========================================================

    IF v_role = 'service_role' THEN

        -- Backend privilegiado pode operar para qualquer usuário.
        NULL;

    ELSIF v_role = 'authenticated' THEN

        -- Cliente autenticado somente pode operar
        -- sobre o próprio usuário.
        IF v_auth_uid IS NULL
           OR p_id_usuario IS DISTINCT FROM v_auth_uid
        THEN
            RAISE EXCEPTION
                'Acesso negado: usuario nao pode acessar carrinho de outro usuario.'
                USING ERRCODE = '42501';
        END IF;

    ELSE

        RAISE EXCEPTION
            'Acesso negado para este papel.'
            USING ERRCODE = '42501';

    END IF;


    -- ========================================================
    -- LOCALIZAR CARRINHO ATIVO
    -- ========================================================

    SELECT c.id_carrinho
      INTO v_id_carrinho
    FROM public.carrinho c
    WHERE c.id_usuario = p_id_usuario
      AND c.status = 'ATIVO'
    LIMIT 1;


    -- ========================================================
    -- CRIAR CASO NAO EXISTA
    -- ========================================================

    IF v_id_carrinho IS NULL THEN

        INSERT INTO public.carrinho (
            id_usuario,
            status
        )
        VALUES (
            p_id_usuario,
            'ATIVO'
        )
        RETURNING id_carrinho
        INTO v_id_carrinho;

    END IF;


    RETURN v_id_carrinho;

END;
$$;


ALTER FUNCTION "public"."obter_ou_criar_carrinho"("p_id_usuario" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."proteger_campos_admin_perfil"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
    -- Operacoes realizadas pelo backend confiavel
    -- com service_role continuam permitidas.
    IF auth.role() = 'service_role' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.tipo_usuario IS DISTINCT FROM 'CLIENTE'
           OR NEW.ativo IS DISTINCT FROM true THEN
            RAISE EXCEPTION
                'Nao e permitido criar perfil com privilegios administrativos.';
        END IF;

    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.tipo_usuario IS DISTINCT FROM OLD.tipo_usuario
           OR NEW.ativo IS DISTINCT FROM OLD.ativo THEN
            RAISE EXCEPTION
                'Nao e permitido alterar campos administrativos do perfil.';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."proteger_campos_admin_perfil"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_historico_status_pedido"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN

    -- --------------------------------------------------------
    -- 1. Novo pedido
    -- Registra o status inicial do pedido.
    -- --------------------------------------------------------
    IF TG_OP = 'INSERT' THEN

        INSERT INTO public.historico_status_pedido (
            id_pedido,
            status,
            descricao,
            data_status
        )
        VALUES (
            NEW.id_pedido,
            NEW.status,
            'Status inicial do pedido.',
            COALESCE(NEW.data_criacao, now())
        );

        RETURN NEW;
    END IF;


    -- --------------------------------------------------------
    -- 2. Alteração do status
    -- Só registra quando houver mudança real de status.
    -- --------------------------------------------------------
    IF TG_OP = 'UPDATE'
       AND OLD.status IS DISTINCT FROM NEW.status THEN

        INSERT INTO public.historico_status_pedido (
            id_pedido,
            status,
            descricao,
            data_status
        )
        VALUES (
            NEW.id_pedido,
            NEW.status,
            'Status do pedido alterado de '
                || COALESCE(OLD.status, 'NULL')
                || ' para '
                || COALESCE(NEW.status, 'NULL')
                || '.',
            now()
        );

        RETURN NEW;
    END IF;


    -- --------------------------------------------------------
    -- 3. UPDATE sem alteração do status
    -- Nenhum histórico adicional deve ser criado.
    -- --------------------------------------------------------
    RETURN NEW;

END;
$$;


ALTER FUNCTION "public"."registrar_historico_status_pedido"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_pagamento"("p_id_pedido" bigint, "p_metodo" character varying, "p_valor" numeric) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_id_pagamento bigint;
    v_status_pedido varchar;
    v_id_usuario uuid;
    v_valor_total numeric;
    v_role text;
    v_auth_uid uuid;
BEGIN
    -- Identificacao do papel JWT no Supabase.
    v_role := auth.role();
    v_auth_uid := auth.uid();

    -- Controle de acesso.
    IF v_role = 'service_role' THEN
        NULL;

    ELSIF v_role = 'authenticated' THEN
        IF v_auth_uid IS NULL THEN
            RAISE EXCEPTION
                'Usuario nao autenticado.'
                USING ERRCODE = '42501';
        END IF;

    ELSE
        RAISE EXCEPTION
            'Acesso negado para este papel.'
            USING ERRCODE = '42501';
    END IF;

    -- Validacao dos parametros.
    IF p_id_pedido IS NULL
       OR p_metodo IS NULL
       OR btrim(p_metodo) = ''
       OR p_valor IS NULL
       OR p_valor <= 0
    THEN
        RAISE EXCEPTION
            'Parametros de pagamento invalidos.';
    END IF;

    -- Bloqueio do pedido durante o registro.
    SELECT
        p.status,
        p.id_usuario,
        p.valor_total
    INTO
        v_status_pedido,
        v_id_usuario,
        v_valor_total
    FROM public.pedido p
    WHERE p.id_pedido = p_id_pedido
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Pedido % nao encontrado.',
            p_id_pedido;
    END IF;

    -- Usuario comum so registra pagamento proprio.
    IF v_role = 'authenticated'
       AND v_id_usuario IS DISTINCT FROM v_auth_uid
    THEN
        RAISE EXCEPTION
            'Acesso negado ao pedido.'
            USING ERRCODE = '42501';
    END IF;

    -- Validacao do status.
    IF v_status_pedido IS DISTINCT FROM
       'aguardando_pagamento'
    THEN
        RAISE EXCEPTION
            'Pedido nao esta aguardando pagamento.';
    END IF;

    -- Validacao do valor exato.
    IF v_valor_total IS NULL
       OR p_valor <> v_valor_total
    THEN
        RAISE EXCEPTION
            'Valor diferente do total do pedido.';
    END IF;

    -- Registro inicial sem confirmar pagamento.
    INSERT INTO public.pagamento (
        id_pedido,
        metodo,
        status,
        valor
    )
    VALUES (
        p_id_pedido,
        p_metodo,
        'pendente',
        p_valor
    )
    RETURNING id_pagamento
    INTO v_id_pagamento;

    RETURN v_id_pagamento;
END;
$$;


ALTER FUNCTION "public"."registrar_pagamento"("p_id_pedido" bigint, "p_metodo" character varying, "p_valor" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resumo_carrinho"("p_id_carrinho" bigint) RETURNS TABLE("quantidade_produtos" bigint, "quantidade_itens" bigint, "subtotal" numeric)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
    select
        count(*)::bigint as quantidade_produtos,
        coalesce(sum(ic.quantidade), 0)::bigint as quantidade_itens,
        coalesce(sum(ic.quantidade * ic.preco_unitario), 0)::numeric
            as subtotal
    from public.item_carrinho ic
    where ic.id_carrinho = p_id_carrinho;
$$;


ALTER FUNCTION "public"."resumo_carrinho"("p_id_carrinho" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validar_carrinho_checkout"("p_id_carrinho" bigint) RETURNS TABLE("valido" boolean, "mensagem" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
    v_status text;
    v_id_usuario uuid;
    v_quantidade_itens bigint;
    v_itens_sem_estoque bigint;
    v_itens_inativos bigint;
BEGIN

    -- 1. Localizar carrinho
    SELECT
        c.status,
        c.id_usuario
    INTO
        v_status,
        v_id_usuario
    FROM public.carrinho c
    WHERE c.id_carrinho = p_id_carrinho;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT false,
            'Carrinho não encontrado.'::text;
        RETURN;
    END IF;

    -- 2. Validar proprietário
    IF auth.uid() IS NULL
       OR v_id_usuario IS DISTINCT FROM auth.uid()
    THEN
        RETURN QUERY
        SELECT false,
            'Acesso não autorizado ao carrinho.'::text;
        RETURN;
    END IF;

    -- 3. Validar status
    IF v_status IS DISTINCT FROM 'ATIVO' THEN
        RETURN QUERY
        SELECT false,
            'Carrinho não está ativo.'::text;
        RETURN;
    END IF;

    -- 4. Verificar existência de itens
    SELECT COUNT(*)
    INTO v_quantidade_itens
    FROM public.item_carrinho ic
    WHERE ic.id_carrinho = p_id_carrinho;

    IF v_quantidade_itens = 0 THEN
        RETURN QUERY
        SELECT false,
            'Carrinho está vazio.'::text;
        RETURN;
    END IF;

    -- 5. NOVA REGRA: produtos devem estar ativos
    SELECT COUNT(*)
    INTO v_itens_inativos
    FROM public.item_carrinho ic
    LEFT JOIN public.produto p
        ON p.id_produto = ic.id_produto
    WHERE ic.id_carrinho = p_id_carrinho
      AND (
          p.id_produto IS NULL
          OR p.ativo IS DISTINCT FROM true
      );

    IF v_itens_inativos > 0 THEN
        RETURN QUERY
        SELECT false,
            'Carrinho contém produto inativo ou indisponível.'::text;
        RETURN;
    END IF;

    -- 6. Validar estoque
    SELECT COUNT(*)
    INTO v_itens_sem_estoque
    FROM public.item_carrinho ic
    LEFT JOIN public.estoque e
        ON e.id_produto = ic.id_produto
    WHERE ic.id_carrinho = p_id_carrinho
      AND (
          e.id_produto IS NULL
          OR ic.quantidade > e.quantidade
      );

    IF v_itens_sem_estoque > 0 THEN
        RETURN QUERY
        SELECT false,
            'Um ou mais produtos possuem estoque insuficiente.'::text;
        RETURN;
    END IF;

    -- 7. Checkout aprovado
    RETURN QUERY
    SELECT true,
        'Carrinho válido para checkout.'::text;

END;
$$;


ALTER FUNCTION "public"."validar_carrinho_checkout"("p_id_carrinho" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validar_cupom"("p_codigo" character varying, "p_valor_compra" numeric) RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
    v_cupom public.cupom%rowtype;
begin
    select *
      into v_cupom
      from public.cupom
     where codigo = upper(trim(p_codigo));

    -- Cupom inexistente
    if not found then
        return false;
    end if;

    -- Cupom inativo
    if not v_cupom.ativo then
        return false;
    end if;

    -- Fora do período de validade
    if now() < v_cupom.data_inicio
       or now() > v_cupom.data_fim then
        return false;
    end if;

    -- Compra abaixo do valor mínimo
    if p_valor_compra < v_cupom.valor_minimo then
        return false;
    end if;

    -- Limite de utilizações atingido
    if v_cupom.limite_uso is not null
       and v_cupom.quantidade_usada >= v_cupom.limite_uso then
        return false;
    end if;

    return true;
end;
$$;


ALTER FUNCTION "public"."validar_cupom"("p_codigo" character varying, "p_valor_compra" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validar_estoque_carrinho"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
    v_estoque_disponivel integer;
begin
    select quantidade
    into v_estoque_disponivel
    from public.estoque
    where id_produto = new.id_produto;

    if v_estoque_disponivel is null then
        raise exception 'Produto sem registro de estoque.';
    end if;

    if new.quantidade > v_estoque_disponivel then
        raise exception
            'Quantidade solicitada (%) maior que o estoque disponível (%).',
            new.quantidade,
            v_estoque_disponivel;
    end if;

    return new;
end;
$$;


ALTER FUNCTION "public"."validar_estoque_carrinho"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validar_transicao_rastreamento"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN

    -- Se o status não mudou, não há transição para validar.
    IF NEW.status_rastreamento IS NOT DISTINCT FROM OLD.status_rastreamento THEN
        RETURN NEW;
    END IF;

    -- --------------------------------------------------------
    -- Transições permitidas:
    --
    -- aguardando_envio
    --      -> enviado
    --
    -- enviado
    --      -> em_transito
    --      -> problema_entrega
    --
    -- em_transito
    --      -> saiu_para_entrega
    --      -> problema_entrega
    --
    -- saiu_para_entrega
    --      -> entregue
    --      -> problema_entrega
    --
    -- problema_entrega
    --      -> em_transito
    --      -> saiu_para_entrega
    --      -> devolvido
    --
    -- entregue
    --      -> devolvido
    --
    -- devolvido
    --      -> estado terminal
    -- --------------------------------------------------------

    IF
        (OLD.status_rastreamento = 'aguardando_envio'
            AND NEW.status_rastreamento = 'enviado')

        OR

        (OLD.status_rastreamento = 'enviado'
            AND NEW.status_rastreamento IN (
                'em_transito',
                'problema_entrega'
            ))

        OR

        (OLD.status_rastreamento = 'em_transito'
            AND NEW.status_rastreamento IN (
                'saiu_para_entrega',
                'problema_entrega'
            ))

        OR

        (OLD.status_rastreamento = 'saiu_para_entrega'
            AND NEW.status_rastreamento IN (
                'entregue',
                'problema_entrega'
            ))

        OR

        (OLD.status_rastreamento = 'problema_entrega'
            AND NEW.status_rastreamento IN (
                'em_transito',
                'saiu_para_entrega',
                'devolvido'
            ))

        OR

        (OLD.status_rastreamento = 'entregue'
            AND NEW.status_rastreamento = 'devolvido')

    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'Transição de rastreamento inválida: % -> %.',
        OLD.status_rastreamento,
        NEW.status_rastreamento
        USING ERRCODE = '23514';

END;
$$;


ALTER FUNCTION "public"."validar_transicao_rastreamento"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."assinatura" (
    "id_assinatura" bigint NOT NULL,
    "id_usuario" "uuid" NOT NULL,
    "nome_plano" character varying(100) NOT NULL,
    "periodicidade" character varying(20) DEFAULT 'MENSAL'::character varying NOT NULL,
    "valor" numeric(10,2) NOT NULL,
    "status" character varying(20) DEFAULT 'ATIVA'::character varying NOT NULL,
    "data_inicio" "date" DEFAULT CURRENT_DATE NOT NULL,
    "data_proxima_cobranca" "date",
    "data_cancelamento" "date",
    "renovacao_automatica" boolean DEFAULT true NOT NULL,
    "data_cadastro" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id_plano" bigint NOT NULL,
    CONSTRAINT "chk_assinatura_cancelamento" CHECK ((("data_cancelamento" IS NULL) OR ("data_cancelamento" >= "data_inicio"))),
    CONSTRAINT "chk_assinatura_nome_plano" CHECK ((("nome_plano")::"text" = ANY (ARRAY[('INICIANTE'::character varying)::"text", ('APRECIADOR'::character varying)::"text", ('ESPECIALISTA'::character varying)::"text"]))),
    CONSTRAINT "chk_assinatura_periodicidade" CHECK ((("periodicidade")::"text" = ANY (ARRAY[('MENSAL'::character varying)::"text", ('BIMESTRAL'::character varying)::"text", ('TRIMESTRAL'::character varying)::"text"]))),
    CONSTRAINT "chk_assinatura_status" CHECK ((("status")::"text" = ANY (ARRAY[('PENDENTE'::character varying)::"text", ('ATIVA'::character varying)::"text", ('PAUSADA'::character varying)::"text", ('CANCELADA'::character varying)::"text", ('EXPIRADA'::character varying)::"text"]))),
    CONSTRAINT "chk_assinatura_valor" CHECK (("valor" >= (0)::numeric))
);


ALTER TABLE "public"."assinatura" OWNER TO "postgres";


ALTER TABLE "public"."assinatura" ALTER COLUMN "id_assinatura" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."assinatura_id_assinatura_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."avaliacao_produto" (
    "id_avaliacao" bigint NOT NULL,
    "id_usuario" "uuid" NOT NULL,
    "id_produto" bigint NOT NULL,
    "id_item_pedido" bigint NOT NULL,
    "nota" smallint NOT NULL,
    "comentario" "text",
    "ativo" boolean DEFAULT true NOT NULL,
    "data_cadastro" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_avaliacao_nota" CHECK ((("nota" >= 1) AND ("nota" <= 5)))
);


ALTER TABLE "public"."avaliacao_produto" OWNER TO "postgres";


ALTER TABLE "public"."avaliacao_produto" ALTER COLUMN "id_avaliacao" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."avaliacao_produto_id_avaliacao_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."beneficio_assinatura" (
    "id_beneficio" bigint NOT NULL,
    "nivel" character varying(20) NOT NULL,
    "nome" character varying(100) NOT NULL,
    "descricao" "text",
    "ativo" boolean DEFAULT true NOT NULL,
    "ordem_exibicao" integer DEFAULT 1 NOT NULL,
    "data_cadastro" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_beneficio_assinatura_nivel" CHECK ((("nivel")::"text" = ANY (ARRAY[('INICIANTE'::character varying)::"text", ('APRECIADOR'::character varying)::"text", ('ESPECIALISTA'::character varying)::"text"]))),
    CONSTRAINT "chk_beneficio_assinatura_ordem" CHECK (("ordem_exibicao" > 0))
);


ALTER TABLE "public"."beneficio_assinatura" OWNER TO "postgres";


ALTER TABLE "public"."beneficio_assinatura" ALTER COLUMN "id_beneficio" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."beneficio_assinatura_id_beneficio_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."carrinho" (
    "id_carrinho" bigint NOT NULL,
    "id_usuario" "uuid" NOT NULL,
    "status" character varying(20) DEFAULT 'ATIVO'::character varying NOT NULL,
    "data_criacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_carrinho_status" CHECK ((("status")::"text" = ANY (ARRAY[('ATIVO'::character varying)::"text", ('FINALIZADO'::character varying)::"text", ('ABANDONADO'::character varying)::"text"])))
);


ALTER TABLE "public"."carrinho" OWNER TO "postgres";


ALTER TABLE "public"."carrinho" ALTER COLUMN "id_carrinho" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."carrinho_id_carrinho_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."categoria" ALTER COLUMN "id_categoria" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."categoria_id_categoria_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cupom" (
    "id_cupom" bigint NOT NULL,
    "codigo" character varying(50) NOT NULL,
    "descricao" character varying(255),
    "tipo_desconto" character varying(20) NOT NULL,
    "valor_desconto" numeric(10,2) NOT NULL,
    "valor_minimo" numeric(10,2) DEFAULT 0 NOT NULL,
    "data_inicio" timestamp with time zone NOT NULL,
    "data_fim" timestamp with time zone NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "limite_uso" integer,
    "quantidade_usada" integer DEFAULT 0 NOT NULL,
    "data_criacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "exclusivo_assinante" boolean DEFAULT false NOT NULL,
    CONSTRAINT "chk_cupom_limite" CHECK ((("limite_uso" IS NULL) OR ("limite_uso" > 0))),
    CONSTRAINT "chk_cupom_periodo" CHECK (("data_fim" > "data_inicio")),
    CONSTRAINT "chk_cupom_quantidade_usada" CHECK (("quantidade_usada" >= 0)),
    CONSTRAINT "chk_cupom_tipo" CHECK ((("tipo_desconto")::"text" = ANY (ARRAY[('percentual'::character varying)::"text", ('fixo'::character varying)::"text"]))),
    CONSTRAINT "chk_cupom_valor" CHECK (("valor_desconto" > (0)::numeric)),
    CONSTRAINT "chk_cupom_valor_minimo" CHECK (("valor_minimo" >= (0)::numeric))
);


ALTER TABLE "public"."cupom" OWNER TO "postgres";


COMMENT ON COLUMN "public"."cupom"."exclusivo_assinante" IS 'Indica se o cupom pode ser utilizado exclusivamente por usuários com assinatura ativa.';



CREATE TABLE IF NOT EXISTS "public"."cupom_categoria" (
    "id_cupom" bigint NOT NULL,
    "id_categoria" bigint NOT NULL
);


ALTER TABLE "public"."cupom_categoria" OWNER TO "postgres";


ALTER TABLE "public"."cupom" ALTER COLUMN "id_cupom" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."cupom_id_cupom_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cupom_produto" (
    "id_cupom" bigint NOT NULL,
    "id_produto" bigint NOT NULL
);


ALTER TABLE "public"."cupom_produto" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."endereco" (
    "id_endereco" bigint NOT NULL,
    "id_usuario" "uuid" NOT NULL,
    "apelido" character varying(50),
    "cep" character varying(9) NOT NULL,
    "logradouro" character varying(150) NOT NULL,
    "numero" character varying(20) NOT NULL,
    "complemento" character varying(100),
    "bairro" character varying(100) NOT NULL,
    "cidade" character varying(100) NOT NULL,
    "estado" character(2) NOT NULL,
    "principal" boolean DEFAULT false NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "data_cadastro" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."endereco" OWNER TO "postgres";


ALTER TABLE "public"."endereco" ALTER COLUMN "id_endereco" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."endereco_id_endereco_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."estoque" (
    "id_estoque" bigint NOT NULL,
    "id_produto" bigint NOT NULL,
    "quantidade" integer DEFAULT 0 NOT NULL,
    "estoque_minimo" integer DEFAULT 0 NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_estoque_minimo" CHECK (("estoque_minimo" >= 0)),
    CONSTRAINT "chk_estoque_quantidade" CHECK (("quantidade" >= 0))
);


ALTER TABLE "public"."estoque" OWNER TO "postgres";


ALTER TABLE "public"."estoque" ALTER COLUMN "id_estoque" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."estoque_id_estoque_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."favorito" (
    "id_favorito" bigint NOT NULL,
    "id_usuario" "uuid" NOT NULL,
    "id_produto" bigint NOT NULL,
    "data_cadastro" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."favorito" OWNER TO "postgres";


ALTER TABLE "public"."favorito" ALTER COLUMN "id_favorito" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."favorito_id_favorito_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."historico_status_pedido" (
    "id_historico" bigint NOT NULL,
    "id_pedido" bigint NOT NULL,
    "status" character varying(30) NOT NULL,
    "descricao" "text",
    "data_status" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_historico_status_pedido" CHECK ((("status")::"text" = ANY (ARRAY[('aguardando_pagamento'::character varying)::"text", ('pago'::character varying)::"text", ('em_preparacao'::character varying)::"text", ('enviado'::character varying)::"text", ('entregue'::character varying)::"text", ('cancelado'::character varying)::"text"])))
);


ALTER TABLE "public"."historico_status_pedido" OWNER TO "postgres";


ALTER TABLE "public"."historico_status_pedido" ALTER COLUMN "id_historico" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."historico_status_pedido_id_historico_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."item_carrinho" (
    "id_item_carrinho" bigint NOT NULL,
    "id_carrinho" bigint NOT NULL,
    "id_produto" bigint NOT NULL,
    "quantidade" integer DEFAULT 1 NOT NULL,
    "preco_unitario" numeric(10,2) NOT NULL,
    "data_adicao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_item_carrinho_preco" CHECK (("preco_unitario" >= (0)::numeric)),
    CONSTRAINT "chk_item_carrinho_quantidade" CHECK (("quantidade" > 0))
);


ALTER TABLE "public"."item_carrinho" OWNER TO "postgres";


ALTER TABLE "public"."item_carrinho" ALTER COLUMN "id_item_carrinho" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."item_carrinho_id_item_carrinho_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."item_pedido" ALTER COLUMN "id_item_pedido" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."item_pedido_id_item_pedido_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."notificacao_assinante" (
    "id_notificacao" bigint NOT NULL,
    "id_usuario" "uuid" NOT NULL,
    "tipo" character varying(30) NOT NULL,
    "titulo" character varying(150) NOT NULL,
    "mensagem" "text" NOT NULL,
    "nivel_minimo" character varying(20),
    "lida" boolean DEFAULT false NOT NULL,
    "ativa" boolean DEFAULT true NOT NULL,
    "data_criacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_leitura" timestamp with time zone,
    CONSTRAINT "chk_notificacao_assinante_leitura" CHECK (((("lida" = false) AND ("data_leitura" IS NULL)) OR (("lida" = true) AND ("data_leitura" IS NOT NULL)))),
    CONSTRAINT "chk_notificacao_assinante_nivel" CHECK ((("nivel_minimo" IS NULL) OR (("nivel_minimo")::"text" = ANY (ARRAY[('INICIANTE'::character varying)::"text", ('APRECIADOR'::character varying)::"text", ('ESPECIALISTA'::character varying)::"text"])))),
    CONSTRAINT "chk_notificacao_assinante_tipo" CHECK ((("tipo")::"text" = ANY (ARRAY[('IDENTIFICACAO'::character varying)::"text", ('VANTAGEM'::character varying)::"text", ('NOVIDADE'::character varying)::"text", ('LANCAMENTO'::character varying)::"text"])))
);


ALTER TABLE "public"."notificacao_assinante" OWNER TO "postgres";


ALTER TABLE "public"."notificacao_assinante" ALTER COLUMN "id_notificacao" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."notificacao_assinante_id_notificacao_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."pagamento" ALTER COLUMN "id_pagamento" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."pagamento_id_pagamento_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."pedido" ALTER COLUMN "id_pedido" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."pedido_id_pedido_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."perfil" (
    "id_usuario" "uuid" NOT NULL,
    "nome" character varying(150) NOT NULL,
    "telefone" character varying(20),
    "data_nascimento" "date",
    "tipo_usuario" character varying(20) DEFAULT 'CLIENTE'::character varying NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "data_cadastro" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sexo" character varying(30),
    CONSTRAINT "chk_perfil_tipo_usuario" CHECK ((("tipo_usuario")::"text" = ANY (ARRAY[('CLIENTE'::character varying)::"text", ('ADMIN'::character varying)::"text"])))
);


ALTER TABLE "public"."perfil" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plano_assinatura" (
    "id_plano" bigint NOT NULL,
    "nome_plano" character varying(30) NOT NULL,
    "periodicidade" character varying(20) NOT NULL,
    "valor" numeric(10,2) NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "data_cadastro" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_plano_assinatura_nome" CHECK ((("nome_plano")::"text" = ANY (ARRAY[('INICIANTE'::character varying)::"text", ('APRECIADOR'::character varying)::"text", ('ESPECIALISTA'::character varying)::"text"]))),
    CONSTRAINT "chk_plano_assinatura_periodicidade" CHECK ((("periodicidade")::"text" = ANY (ARRAY[('MENSAL'::character varying)::"text", ('BIMESTRAL'::character varying)::"text", ('TRIMESTRAL'::character varying)::"text"]))),
    CONSTRAINT "chk_plano_assinatura_valor" CHECK (("valor" > (0)::numeric))
);


ALTER TABLE "public"."plano_assinatura" OWNER TO "postgres";


ALTER TABLE "public"."plano_assinatura" ALTER COLUMN "id_plano" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."plano_assinatura_id_plano_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."produto" ALTER COLUMN "id_produto" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."produto_id_produto_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."rastreamento_pedido" (
    "id_rastreamento" bigint NOT NULL,
    "id_pedido" bigint NOT NULL,
    "transportadora" character varying(120),
    "codigo_rastreamento" character varying(120),
    "status_rastreamento" character varying(80) DEFAULT 'aguardando_envio'::character varying NOT NULL,
    "localizacao" character varying(255),
    "previsao_entrega" "date",
    "ultima_atualizacao_externa" timestamp with time zone,
    "data_criacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_atualizacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_rastreamento_status" CHECK ((("status_rastreamento")::"text" = ANY (ARRAY[('aguardando_envio'::character varying)::"text", ('enviado'::character varying)::"text", ('em_transito'::character varying)::"text", ('saiu_para_entrega'::character varying)::"text", ('entregue'::character varying)::"text", ('problema_entrega'::character varying)::"text", ('devolvido'::character varying)::"text"])))
);


ALTER TABLE "public"."rastreamento_pedido" OWNER TO "postgres";


ALTER TABLE "public"."rastreamento_pedido" ALTER COLUMN "id_rastreamento" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."rastreamento_pedido_id_rastreamento_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."assinatura"
    ADD CONSTRAINT "assinatura_pkey" PRIMARY KEY ("id_assinatura");



ALTER TABLE ONLY "public"."avaliacao_produto"
    ADD CONSTRAINT "avaliacao_produto_pkey" PRIMARY KEY ("id_avaliacao");



ALTER TABLE ONLY "public"."beneficio_assinatura"
    ADD CONSTRAINT "beneficio_assinatura_pkey" PRIMARY KEY ("id_beneficio");



ALTER TABLE ONLY "public"."carrinho"
    ADD CONSTRAINT "carrinho_pkey" PRIMARY KEY ("id_carrinho");



ALTER TABLE ONLY "public"."categoria"
    ADD CONSTRAINT "categoria_nome_key" UNIQUE ("nome");



ALTER TABLE ONLY "public"."categoria"
    ADD CONSTRAINT "categoria_pkey" PRIMARY KEY ("id_categoria");



ALTER TABLE ONLY "public"."cupom_categoria"
    ADD CONSTRAINT "cupom_categoria_pkey" PRIMARY KEY ("id_cupom", "id_categoria");



ALTER TABLE ONLY "public"."cupom"
    ADD CONSTRAINT "cupom_codigo_key" UNIQUE ("codigo");



ALTER TABLE ONLY "public"."cupom"
    ADD CONSTRAINT "cupom_pkey" PRIMARY KEY ("id_cupom");



ALTER TABLE ONLY "public"."cupom_produto"
    ADD CONSTRAINT "cupom_produto_pkey" PRIMARY KEY ("id_cupom", "id_produto");



ALTER TABLE ONLY "public"."endereco"
    ADD CONSTRAINT "endereco_pkey" PRIMARY KEY ("id_endereco");



ALTER TABLE ONLY "public"."estoque"
    ADD CONSTRAINT "estoque_id_produto_key" UNIQUE ("id_produto");



ALTER TABLE ONLY "public"."estoque"
    ADD CONSTRAINT "estoque_pkey" PRIMARY KEY ("id_estoque");



ALTER TABLE ONLY "public"."favorito"
    ADD CONSTRAINT "favorito_pkey" PRIMARY KEY ("id_favorito");



ALTER TABLE ONLY "public"."historico_status_pedido"
    ADD CONSTRAINT "historico_status_pedido_pkey" PRIMARY KEY ("id_historico");



ALTER TABLE ONLY "public"."item_carrinho"
    ADD CONSTRAINT "item_carrinho_pkey" PRIMARY KEY ("id_item_carrinho");



ALTER TABLE ONLY "public"."item_pedido"
    ADD CONSTRAINT "item_pedido_pkey" PRIMARY KEY ("id_item_pedido");



ALTER TABLE ONLY "public"."notificacao_assinante"
    ADD CONSTRAINT "notificacao_assinante_pkey" PRIMARY KEY ("id_notificacao");



ALTER TABLE ONLY "public"."pagamento"
    ADD CONSTRAINT "pagamento_pkey" PRIMARY KEY ("id_pagamento");



ALTER TABLE ONLY "public"."pedido"
    ADD CONSTRAINT "pedido_pkey" PRIMARY KEY ("id_pedido");



ALTER TABLE ONLY "public"."perfil"
    ADD CONSTRAINT "perfil_pkey" PRIMARY KEY ("id_usuario");



ALTER TABLE ONLY "public"."plano_assinatura"
    ADD CONSTRAINT "plano_assinatura_pkey" PRIMARY KEY ("id_plano");



ALTER TABLE ONLY "public"."produto"
    ADD CONSTRAINT "produto_pkey" PRIMARY KEY ("id_produto");



ALTER TABLE ONLY "public"."produto"
    ADD CONSTRAINT "produto_sku_key" UNIQUE ("sku");



ALTER TABLE ONLY "public"."rastreamento_pedido"
    ADD CONSTRAINT "rastreamento_pedido_pkey" PRIMARY KEY ("id_rastreamento");



ALTER TABLE ONLY "public"."avaliacao_produto"
    ADD CONSTRAINT "uq_avaliacao_item_pedido" UNIQUE ("id_item_pedido");



ALTER TABLE ONLY "public"."beneficio_assinatura"
    ADD CONSTRAINT "uq_beneficio_assinatura_nivel_nome" UNIQUE ("nivel", "nome");



ALTER TABLE ONLY "public"."favorito"
    ADD CONSTRAINT "uq_favorito_usuario_produto" UNIQUE ("id_usuario", "id_produto");



ALTER TABLE ONLY "public"."item_carrinho"
    ADD CONSTRAINT "uq_item_carrinho_produto" UNIQUE ("id_carrinho", "id_produto");



ALTER TABLE ONLY "public"."item_pedido"
    ADD CONSTRAINT "uq_item_pedido_produto" UNIQUE ("id_pedido", "id_produto");



ALTER TABLE ONLY "public"."pagamento"
    ADD CONSTRAINT "uq_pagamento_pedido" UNIQUE ("id_pedido");



ALTER TABLE ONLY "public"."plano_assinatura"
    ADD CONSTRAINT "uq_plano_assinatura" UNIQUE ("nome_plano", "periodicidade");



ALTER TABLE ONLY "public"."rastreamento_pedido"
    ADD CONSTRAINT "uq_rastreamento_pedido" UNIQUE ("id_pedido");



CREATE INDEX "idx_assinatura_proxima_cobranca" ON "public"."assinatura" USING "btree" ("data_proxima_cobranca");



CREATE INDEX "idx_assinatura_status" ON "public"."assinatura" USING "btree" ("status");



CREATE INDEX "idx_assinatura_usuario" ON "public"."assinatura" USING "btree" ("id_usuario");



CREATE INDEX "idx_avaliacao_produto" ON "public"."avaliacao_produto" USING "btree" ("id_produto");



CREATE INDEX "idx_avaliacao_usuario" ON "public"."avaliacao_produto" USING "btree" ("id_usuario");



CREATE INDEX "idx_beneficio_assinatura_ativo" ON "public"."beneficio_assinatura" USING "btree" ("ativo");



CREATE INDEX "idx_beneficio_assinatura_nivel" ON "public"."beneficio_assinatura" USING "btree" ("nivel");



CREATE INDEX "idx_cupom_categoria_id_categoria" ON "public"."cupom_categoria" USING "btree" ("id_categoria");



CREATE INDEX "idx_cupom_produto_id_produto" ON "public"."cupom_produto" USING "btree" ("id_produto");



CREATE INDEX "idx_endereco_id_usuario" ON "public"."endereco" USING "btree" ("id_usuario");



CREATE INDEX "idx_favorito_produto" ON "public"."favorito" USING "btree" ("id_produto");



CREATE INDEX "idx_favorito_usuario" ON "public"."favorito" USING "btree" ("id_usuario");



CREATE INDEX "idx_historico_status_pedido_data" ON "public"."historico_status_pedido" USING "btree" ("id_pedido", "data_status" DESC);



CREATE INDEX "idx_historico_status_pedido_id_pedido" ON "public"."historico_status_pedido" USING "btree" ("id_pedido");



CREATE INDEX "idx_item_carrinho_id_produto" ON "public"."item_carrinho" USING "btree" ("id_produto");



CREATE INDEX "idx_item_pedido_id_produto" ON "public"."item_pedido" USING "btree" ("id_produto");



CREATE INDEX "idx_notificacao_assinante_data" ON "public"."notificacao_assinante" USING "btree" ("data_criacao" DESC);



CREATE INDEX "idx_notificacao_assinante_usuario" ON "public"."notificacao_assinante" USING "btree" ("id_usuario");



CREATE INDEX "idx_notificacao_assinante_usuario_ativa" ON "public"."notificacao_assinante" USING "btree" ("id_usuario", "ativa");



CREATE INDEX "idx_pedido_id_carrinho" ON "public"."pedido" USING "btree" ("id_carrinho");



CREATE INDEX "idx_pedido_id_cupom" ON "public"."pedido" USING "btree" ("id_cupom");



CREATE INDEX "idx_pedido_id_endereco" ON "public"."pedido" USING "btree" ("id_endereco");



CREATE INDEX "idx_pedido_id_usuario" ON "public"."pedido" USING "btree" ("id_usuario");



CREATE INDEX "idx_produto_id_categoria" ON "public"."produto" USING "btree" ("id_categoria");



CREATE INDEX "idx_rastreamento_codigo" ON "public"."rastreamento_pedido" USING "btree" ("codigo_rastreamento") WHERE ("codigo_rastreamento" IS NOT NULL);



CREATE INDEX "idx_rastreamento_status" ON "public"."rastreamento_pedido" USING "btree" ("status_rastreamento");



CREATE UNIQUE INDEX "uq_assinatura_usuario_em_andamento" ON "public"."assinatura" USING "btree" ("id_usuario") WHERE (("status")::"text" = ANY (ARRAY[('PENDENTE'::character varying)::"text", ('ATIVA'::character varying)::"text", ('PAUSADA'::character varying)::"text"]));



CREATE UNIQUE INDEX "uq_carrinho_ativo_usuario" ON "public"."carrinho" USING "btree" ("id_usuario") WHERE (("status")::"text" = 'ATIVO'::"text");



CREATE UNIQUE INDEX "uq_endereco_principal_usuario" ON "public"."endereco" USING "btree" ("id_usuario") WHERE ("principal" = true);



CREATE UNIQUE INDEX "uq_pedido_checkout_aberto_por_carrinho" ON "public"."pedido" USING "btree" ("id_carrinho") WHERE (("status")::"text" = 'aguardando_pagamento'::"text");



CREATE OR REPLACE TRIGGER "trg_atualizar_data_carrinho" AFTER INSERT OR DELETE OR UPDATE ON "public"."item_carrinho" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_data_carrinho"();



CREATE OR REPLACE TRIGGER "trg_atualizar_data_carrinho_registro" BEFORE UPDATE ON "public"."carrinho" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_data_atualizacao"();



CREATE OR REPLACE TRIGGER "trg_atualizar_data_endereco" BEFORE UPDATE ON "public"."endereco" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_data_atualizacao"();



CREATE OR REPLACE TRIGGER "trg_atualizar_data_estoque" BEFORE UPDATE ON "public"."estoque" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_data_atualizacao"();



CREATE OR REPLACE TRIGGER "trg_atualizar_data_item_carrinho" BEFORE UPDATE ON "public"."item_carrinho" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_data_atualizacao"();



CREATE OR REPLACE TRIGGER "trg_atualizar_data_pagamento" BEFORE UPDATE ON "public"."pagamento" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_data_atualizacao"();



CREATE OR REPLACE TRIGGER "trg_atualizar_data_pedido" BEFORE UPDATE ON "public"."pedido" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_data_atualizacao"();



CREATE OR REPLACE TRIGGER "trg_atualizar_data_perfil" BEFORE UPDATE ON "public"."perfil" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_data_atualizacao"();



CREATE OR REPLACE TRIGGER "trg_atualizar_data_produto" BEFORE UPDATE ON "public"."produto" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_data_atualizacao"();



CREATE OR REPLACE TRIGGER "trg_atualizar_data_rastreamento" BEFORE UPDATE ON "public"."rastreamento_pedido" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_data_rastreamento"();



CREATE OR REPLACE TRIGGER "trg_definir_preco_oficial_carrinho" BEFORE INSERT OR UPDATE ON "public"."item_carrinho" FOR EACH ROW EXECUTE FUNCTION "public"."definir_preco_oficial_carrinho"();



CREATE OR REPLACE TRIGGER "trg_proteger_campos_admin_perfil" BEFORE INSERT OR UPDATE ON "public"."perfil" FOR EACH ROW EXECUTE FUNCTION "public"."proteger_campos_admin_perfil"();



CREATE OR REPLACE TRIGGER "trg_registrar_historico_status_pedido" AFTER INSERT OR UPDATE OF "status" ON "public"."pedido" FOR EACH ROW EXECUTE FUNCTION "public"."registrar_historico_status_pedido"();



CREATE OR REPLACE TRIGGER "trg_validar_estoque_carrinho" BEFORE INSERT OR UPDATE OF "quantidade", "id_produto" ON "public"."item_carrinho" FOR EACH ROW EXECUTE FUNCTION "public"."validar_estoque_carrinho"();



CREATE OR REPLACE TRIGGER "trg_validar_transicao_rastreamento" BEFORE UPDATE OF "status_rastreamento" ON "public"."rastreamento_pedido" FOR EACH ROW WHEN ((("old"."status_rastreamento")::"text" IS DISTINCT FROM ("new"."status_rastreamento")::"text")) EXECUTE FUNCTION "public"."validar_transicao_rastreamento"();



ALTER TABLE ONLY "public"."assinatura"
    ADD CONSTRAINT "fk_assinatura_plano" FOREIGN KEY ("id_plano") REFERENCES "public"."plano_assinatura"("id_plano");



ALTER TABLE ONLY "public"."assinatura"
    ADD CONSTRAINT "fk_assinatura_usuario" FOREIGN KEY ("id_usuario") REFERENCES "public"."perfil"("id_usuario") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."avaliacao_produto"
    ADD CONSTRAINT "fk_avaliacao_item_pedido" FOREIGN KEY ("id_item_pedido") REFERENCES "public"."item_pedido"("id_item_pedido") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."avaliacao_produto"
    ADD CONSTRAINT "fk_avaliacao_produto" FOREIGN KEY ("id_produto") REFERENCES "public"."produto"("id_produto") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."avaliacao_produto"
    ADD CONSTRAINT "fk_avaliacao_usuario" FOREIGN KEY ("id_usuario") REFERENCES "public"."perfil"("id_usuario") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."carrinho"
    ADD CONSTRAINT "fk_carrinho_usuario" FOREIGN KEY ("id_usuario") REFERENCES "public"."perfil"("id_usuario") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cupom_categoria"
    ADD CONSTRAINT "fk_cupom_categoria_categoria" FOREIGN KEY ("id_categoria") REFERENCES "public"."categoria"("id_categoria") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cupom_categoria"
    ADD CONSTRAINT "fk_cupom_categoria_cupom" FOREIGN KEY ("id_cupom") REFERENCES "public"."cupom"("id_cupom") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cupom_produto"
    ADD CONSTRAINT "fk_cupom_produto_cupom" FOREIGN KEY ("id_cupom") REFERENCES "public"."cupom"("id_cupom") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cupom_produto"
    ADD CONSTRAINT "fk_cupom_produto_produto" FOREIGN KEY ("id_produto") REFERENCES "public"."produto"("id_produto") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."endereco"
    ADD CONSTRAINT "fk_endereco_usuario" FOREIGN KEY ("id_usuario") REFERENCES "public"."perfil"("id_usuario") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."estoque"
    ADD CONSTRAINT "fk_estoque_produto" FOREIGN KEY ("id_produto") REFERENCES "public"."produto"("id_produto");



ALTER TABLE ONLY "public"."favorito"
    ADD CONSTRAINT "fk_favorito_produto" FOREIGN KEY ("id_produto") REFERENCES "public"."produto"("id_produto") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."favorito"
    ADD CONSTRAINT "fk_favorito_usuario" FOREIGN KEY ("id_usuario") REFERENCES "public"."perfil"("id_usuario") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."historico_status_pedido"
    ADD CONSTRAINT "fk_historico_status_pedido" FOREIGN KEY ("id_pedido") REFERENCES "public"."pedido"("id_pedido") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_carrinho"
    ADD CONSTRAINT "fk_item_carrinho_carrinho" FOREIGN KEY ("id_carrinho") REFERENCES "public"."carrinho"("id_carrinho") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_carrinho"
    ADD CONSTRAINT "fk_item_carrinho_produto" FOREIGN KEY ("id_produto") REFERENCES "public"."produto"("id_produto");



ALTER TABLE ONLY "public"."item_pedido"
    ADD CONSTRAINT "fk_item_pedido_pedido" FOREIGN KEY ("id_pedido") REFERENCES "public"."pedido"("id_pedido") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_pedido"
    ADD CONSTRAINT "fk_item_pedido_produto" FOREIGN KEY ("id_produto") REFERENCES "public"."produto"("id_produto");



ALTER TABLE ONLY "public"."notificacao_assinante"
    ADD CONSTRAINT "fk_notificacao_assinante_usuario" FOREIGN KEY ("id_usuario") REFERENCES "public"."perfil"("id_usuario") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pagamento"
    ADD CONSTRAINT "fk_pagamento_pedido" FOREIGN KEY ("id_pedido") REFERENCES "public"."pedido"("id_pedido");



ALTER TABLE ONLY "public"."pedido"
    ADD CONSTRAINT "fk_pedido_carrinho" FOREIGN KEY ("id_carrinho") REFERENCES "public"."carrinho"("id_carrinho");



ALTER TABLE ONLY "public"."pedido"
    ADD CONSTRAINT "fk_pedido_cupom" FOREIGN KEY ("id_cupom") REFERENCES "public"."cupom"("id_cupom") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pedido"
    ADD CONSTRAINT "fk_pedido_endereco" FOREIGN KEY ("id_endereco") REFERENCES "public"."endereco"("id_endereco");



ALTER TABLE ONLY "public"."pedido"
    ADD CONSTRAINT "fk_pedido_usuario" FOREIGN KEY ("id_usuario") REFERENCES "public"."perfil"("id_usuario");



ALTER TABLE ONLY "public"."perfil"
    ADD CONSTRAINT "fk_perfil_usuario" FOREIGN KEY ("id_usuario") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."produto"
    ADD CONSTRAINT "fk_produto_categoria" FOREIGN KEY ("id_categoria") REFERENCES "public"."categoria"("id_categoria");



ALTER TABLE ONLY "public"."rastreamento_pedido"
    ADD CONSTRAINT "fk_rastreamento_pedido" FOREIGN KEY ("id_pedido") REFERENCES "public"."pedido"("id_pedido") ON DELETE CASCADE;



CREATE POLICY "Admin atualiza categorias" ON "public"."categoria" FOR UPDATE TO "authenticated" USING ("public"."eh_admin"()) WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin atualiza cupons" ON "public"."cupom" FOR UPDATE TO "authenticated" USING ("public"."eh_admin"()) WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin atualiza estoque" ON "public"."estoque" FOR UPDATE TO "authenticated" USING ("public"."eh_admin"()) WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin atualiza pagamentos" ON "public"."pagamento" FOR UPDATE TO "authenticated" USING ("public"."eh_admin"()) WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin atualiza pedidos" ON "public"."pedido" FOR UPDATE TO "authenticated" USING ("public"."eh_admin"()) WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin atualiza produtos" ON "public"."produto" FOR UPDATE TO "authenticated" USING ("public"."eh_admin"()) WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin cria cupom_categoria" ON "public"."cupom_categoria" FOR INSERT TO "authenticated" WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin cria cupom_produto" ON "public"."cupom_produto" FOR INSERT TO "authenticated" WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin cria cupons" ON "public"."cupom" FOR INSERT TO "authenticated" WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin exclui categorias" ON "public"."categoria" FOR DELETE TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Admin exclui cupom_categoria" ON "public"."cupom_categoria" FOR DELETE TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Admin exclui cupom_produto" ON "public"."cupom_produto" FOR DELETE TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Admin exclui cupons" ON "public"."cupom" FOR DELETE TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Admin exclui estoque" ON "public"."estoque" FOR DELETE TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Admin exclui produtos" ON "public"."produto" FOR DELETE TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Admin insere categorias" ON "public"."categoria" FOR INSERT TO "authenticated" WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin insere estoque" ON "public"."estoque" FOR INSERT TO "authenticated" WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin insere produtos" ON "public"."produto" FOR INSERT TO "authenticated" WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin registra historico dos pedidos" ON "public"."historico_status_pedido" FOR INSERT TO "authenticated" WITH CHECK ("public"."eh_admin"());



CREATE POLICY "Admin visualiza cupom_categoria" ON "public"."cupom_categoria" FOR SELECT TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Admin visualiza cupom_produto" ON "public"."cupom_produto" FOR SELECT TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Admin visualiza cupons" ON "public"."cupom" FOR SELECT TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Admin visualiza estoque" ON "public"."estoque" FOR SELECT TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Admin visualiza pagamentos" ON "public"."pagamento" FOR SELECT TO "authenticated" USING ("public"."eh_admin"());



CREATE POLICY "Categorias visiveis para todos" ON "public"."categoria" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Consulta publica de planos ativos" ON "public"."plano_assinatura" FOR SELECT TO "anon", "authenticated" USING (("ativo" = true));



CREATE POLICY "Produtos visiveis para todos" ON "public"."produto" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Usuario adiciona itens aos proprios carrinhos" ON "public"."item_carrinho" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."carrinho" "c"
  WHERE (("c"."id_carrinho" = "item_carrinho"."id_carrinho") AND ("c"."id_usuario" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Usuario adiciona itens aos proprios pedidos" ON "public"."item_pedido" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."pedido" "p"
  WHERE (("p"."id_pedido" = "item_pedido"."id_pedido") AND ("p"."id_usuario" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Usuario adiciona proprios favoritos" ON "public"."favorito" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario atualiza itens dos proprios carrinhos" ON "public"."item_carrinho" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."carrinho" "c"
  WHERE (("c"."id_carrinho" = "item_carrinho"."id_carrinho") AND ("c"."id_usuario" = ( SELECT "auth"."uid"() AS "uid")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."carrinho" "c"
  WHERE (("c"."id_carrinho" = "item_carrinho"."id_carrinho") AND ("c"."id_usuario" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Usuario atualiza propria assinatura" ON "public"."assinatura" FOR UPDATE TO "authenticated" USING (((( SELECT "auth"."uid"() AS "uid") = "id_usuario") OR "public"."eh_admin"())) WITH CHECK (((( SELECT "auth"."uid"() AS "uid") = "id_usuario") OR "public"."eh_admin"()));



CREATE POLICY "Usuario atualiza propria avaliacao" ON "public"."avaliacao_produto" FOR UPDATE TO "authenticated" USING (("id_usuario" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK ((("id_usuario" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM ("public"."item_pedido" "ip"
     JOIN "public"."pedido" "p" ON (("p"."id_pedido" = "ip"."id_pedido")))
  WHERE (("ip"."id_item_pedido" = "avaliacao_produto"."id_item_pedido") AND ("ip"."id_produto" = "avaliacao_produto"."id_produto") AND ("p"."id_usuario" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "Usuario atualiza proprias notificacoes" ON "public"."notificacao_assinante" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario atualiza proprio carrinho" ON "public"."carrinho" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario atualiza proprio endereco" ON "public"."endereco" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario atualiza proprio perfil" ON "public"."perfil" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario avalia produto comprado" ON "public"."avaliacao_produto" FOR INSERT TO "authenticated" WITH CHECK ((("id_usuario" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM ("public"."item_pedido" "ip"
     JOIN "public"."pedido" "p" ON (("p"."id_pedido" = "ip"."id_pedido")))
  WHERE (("ip"."id_item_pedido" = "avaliacao_produto"."id_item_pedido") AND ("ip"."id_produto" = "avaliacao_produto"."id_produto") AND ("p"."id_usuario" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "Usuario cadastra proprio endereco" ON "public"."endereco" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario cria propria assinatura" ON "public"."assinatura" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario cria proprio carrinho" ON "public"."carrinho" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario cria proprio pedido" ON "public"."pedido" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario exclui propria avaliacao" ON "public"."avaliacao_produto" FOR DELETE TO "authenticated" USING (("id_usuario" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Usuario exclui proprio carrinho" ON "public"."carrinho" FOR DELETE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario exclui proprio endereco" ON "public"."endereco" FOR DELETE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario remove itens dos proprios carrinhos" ON "public"."item_carrinho" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."carrinho" "c"
  WHERE (("c"."id_carrinho" = "item_carrinho"."id_carrinho") AND ("c"."id_usuario" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Usuario remove proprios favoritos" ON "public"."favorito" FOR DELETE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario visualiza avaliacoes" ON "public"."avaliacao_produto" FOR SELECT TO "authenticated" USING ((("ativo" = true) OR ("id_usuario" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "Usuario visualiza historico dos proprios pedidos" ON "public"."historico_status_pedido" FOR SELECT TO "authenticated" USING (("public"."eh_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."pedido" "p"
  WHERE (("p"."id_pedido" = "historico_status_pedido"."id_pedido") AND ("p"."id_usuario" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "Usuario visualiza itens dos proprios carrinhos" ON "public"."item_carrinho" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."carrinho" "c"
  WHERE (("c"."id_carrinho" = "item_carrinho"."id_carrinho") AND ("c"."id_usuario" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Usuario visualiza itens dos proprios pedidos" ON "public"."item_pedido" FOR SELECT TO "authenticated" USING (("public"."eh_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."pedido" "p"
  WHERE (("p"."id_pedido" = "item_pedido"."id_pedido") AND ("p"."id_usuario" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "Usuario visualiza proprias assinaturas" ON "public"."assinatura" FOR SELECT TO "authenticated" USING (((( SELECT "auth"."uid"() AS "uid") = "id_usuario") OR "public"."eh_admin"()));



CREATE POLICY "Usuario visualiza proprias notificacoes" ON "public"."notificacao_assinante" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario visualiza proprio perfil" ON "public"."perfil" FOR SELECT TO "authenticated" USING (((( SELECT "auth"."uid"() AS "uid") = "id_usuario") OR ( SELECT "public"."eh_admin"() AS "eh_admin")));



CREATE POLICY "Usuario visualiza proprios carrinhos" ON "public"."carrinho" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario visualiza proprios enderecos" ON "public"."endereco" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario visualiza proprios favoritos" ON "public"."favorito" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id_usuario"));



CREATE POLICY "Usuario visualiza proprios pedidos" ON "public"."pedido" FOR SELECT TO "authenticated" USING (((( SELECT "auth"."uid"() AS "uid") = "id_usuario") OR ( SELECT "public"."eh_admin"() AS "eh_admin")));



CREATE POLICY "Usuario visualiza rastreamento dos proprios pedidos" ON "public"."rastreamento_pedido" FOR SELECT TO "authenticated" USING ((( SELECT "public"."eh_admin"() AS "eh_admin") OR (EXISTS ( SELECT 1
   FROM "public"."pedido" "p"
  WHERE (("p"."id_pedido" = "rastreamento_pedido"."id_pedido") AND ("p"."id_usuario" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "Usuarios consultam beneficios ativos" ON "public"."beneficio_assinatura" FOR SELECT TO "authenticated" USING (("ativo" = true));



ALTER TABLE "public"."assinatura" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."avaliacao_produto" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."beneficio_assinatura" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."carrinho" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."categoria" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cupom" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cupom_categoria" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cupom_produto" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."endereco" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."estoque" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."favorito" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."historico_status_pedido" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."item_carrinho" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."item_pedido" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notificacao_assinante" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pagamento" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pedido" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."perfil" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plano_assinatura" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."produto" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rastreamento_pedido" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."aplicar_cupom"("p_codigo" character varying, "p_valor_compra" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."aplicar_cupom"("p_codigo" character varying, "p_valor_compra" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."aplicar_cupom"("p_codigo" character varying, "p_valor_compra" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."aplicar_cupom_pedido"("p_id_pedido" bigint, "p_codigo" character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."aplicar_cupom_pedido"("p_id_pedido" bigint, "p_codigo" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."aplicar_cupom_pedido"("p_id_pedido" bigint, "p_codigo" character varying) TO "service_role";



REVOKE ALL ON FUNCTION "public"."atualizar_data_atualizacao"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."atualizar_data_atualizacao"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_data_atualizacao"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."atualizar_data_carrinho"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."atualizar_data_carrinho"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."atualizar_data_rastreamento"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."atualizar_data_rastreamento"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_data_rastreamento"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."atualizar_estoque_admin"("p_id_produto" bigint, "p_quantidade" integer, "p_estoque_minimo" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."atualizar_estoque_admin"("p_id_produto" bigint, "p_quantidade" integer, "p_estoque_minimo" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_estoque_admin"("p_id_produto" bigint, "p_quantidade" integer, "p_estoque_minimo" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."atualizar_status_pagamento"("p_id_pagamento" bigint, "p_novo_status" character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."atualizar_status_pagamento"("p_id_pagamento" bigint, "p_novo_status" character varying) TO "service_role";



REVOKE ALL ON FUNCTION "public"."atualizar_status_pedido_admin"("p_id_pedido" bigint, "p_novo_status" character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."atualizar_status_pedido_admin"("p_id_pedido" bigint, "p_novo_status" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_status_pedido_admin"("p_id_pedido" bigint, "p_novo_status" character varying) TO "service_role";



REVOKE ALL ON FUNCTION "public"."calcular_base_elegivel_cupom"("p_id_pedido" bigint, "p_id_cupom" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."calcular_base_elegivel_cupom"("p_id_pedido" bigint, "p_id_cupom" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calcular_base_elegivel_cupom"("p_id_pedido" bigint, "p_id_cupom" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."calcular_desconto_cupom"("p_codigo" character varying, "p_valor_compra" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."calcular_desconto_cupom"("p_codigo" character varying, "p_valor_compra" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calcular_desconto_cupom"("p_codigo" character varying, "p_valor_compra" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."cancelar_assinatura"("p_id_assinatura" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancelar_assinatura"("p_id_assinatura" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancelar_assinatura"("p_id_assinatura" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."contratar_assinatura"("p_id_plano" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."contratar_assinatura"("p_id_plano" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."contratar_assinatura"("p_id_plano" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."criar_notificacao_assinante"("p_id_usuario" "uuid", "p_tipo" character varying, "p_titulo" character varying, "p_mensagem" "text", "p_nivel_minimo" character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."criar_notificacao_assinante"("p_id_usuario" "uuid", "p_tipo" character varying, "p_titulo" character varying, "p_mensagem" "text", "p_nivel_minimo" character varying) TO "service_role";



REVOKE ALL ON FUNCTION "public"."criar_pedido"("p_id_carrinho" bigint, "p_id_endereco" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."criar_pedido"("p_id_carrinho" bigint, "p_id_endereco" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."criar_pedido"("p_id_carrinho" bigint, "p_id_endereco" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."criar_perfil_novo_usuario"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."criar_perfil_novo_usuario"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."dashboard_produtos_mais_vendidos"("p_limite" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dashboard_produtos_mais_vendidos"("p_limite" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."dashboard_produtos_mais_vendidos"("p_limite" integer) TO "service_role";



GRANT ALL ON TABLE "public"."categoria" TO "anon";
GRANT ALL ON TABLE "public"."categoria" TO "authenticated";
GRANT ALL ON TABLE "public"."categoria" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."item_pedido" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."item_pedido" TO "authenticated";
GRANT ALL ON TABLE "public"."item_pedido" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pagamento" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pagamento" TO "authenticated";
GRANT ALL ON TABLE "public"."pagamento" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pedido" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pedido" TO "authenticated";
GRANT ALL ON TABLE "public"."pedido" TO "service_role";



GRANT ALL ON TABLE "public"."produto" TO "anon";
GRANT ALL ON TABLE "public"."produto" TO "authenticated";
GRANT ALL ON TABLE "public"."produto" TO "service_role";



GRANT ALL ON TABLE "public"."vw_vendas_detalhadas" TO "service_role";



REVOKE ALL ON FUNCTION "public"."dashboard_vendas_exportacao"("p_data_inicio" "date", "p_data_fim" "date", "p_id_produto" bigint, "p_categoria" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dashboard_vendas_exportacao"("p_data_inicio" "date", "p_data_fim" "date", "p_id_produto" bigint, "p_categoria" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dashboard_vendas_exportacao"("p_data_inicio" "date", "p_data_fim" "date", "p_id_produto" bigint, "p_categoria" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."dashboard_vendas_filtradas"("p_data_inicio" "date", "p_data_fim" "date", "p_id_produto" bigint, "p_categoria" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dashboard_vendas_filtradas"("p_data_inicio" "date", "p_data_fim" "date", "p_id_produto" bigint, "p_categoria" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dashboard_vendas_filtradas"("p_data_inicio" "date", "p_data_fim" "date", "p_id_produto" bigint, "p_categoria" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."dashboard_vendas_kpis"("p_data_inicial" "date", "p_data_final" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dashboard_vendas_kpis"("p_data_inicial" "date", "p_data_final" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dashboard_vendas_kpis"("p_data_inicial" "date", "p_data_final" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."definir_preco_oficial_carrinho"() TO "anon";
GRANT ALL ON FUNCTION "public"."definir_preco_oficial_carrinho"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."definir_preco_oficial_carrinho"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."desativar_renovacao_assinatura"("p_id_assinatura" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."desativar_renovacao_assinatura"("p_id_assinatura" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."desativar_renovacao_assinatura"("p_id_assinatura" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."eh_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eh_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."eh_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."limpar_carrinho"("p_id_carrinho" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."limpar_carrinho"("p_id_carrinho" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."limpar_carrinho"("p_id_carrinho" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."listar_clientes_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."listar_clientes_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."listar_clientes_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."obter_beneficios_assinante"("p_id_usuario" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."obter_beneficios_assinante"("p_id_usuario" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."obter_beneficios_assinante"("p_id_usuario" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."obter_nivel_assinante"("p_id_usuario" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."obter_nivel_assinante"("p_id_usuario" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."obter_nivel_assinante"("p_id_usuario" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."obter_ou_criar_carrinho"("p_id_usuario" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."obter_ou_criar_carrinho"("p_id_usuario" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."obter_ou_criar_carrinho"("p_id_usuario" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."proteger_campos_admin_perfil"() TO "anon";
GRANT ALL ON FUNCTION "public"."proteger_campos_admin_perfil"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."proteger_campos_admin_perfil"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_historico_status_pedido"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_historico_status_pedido"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_historico_status_pedido"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_pagamento"("p_id_pedido" bigint, "p_metodo" character varying, "p_valor" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_pagamento"("p_id_pedido" bigint, "p_metodo" character varying, "p_valor" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_pagamento"("p_id_pedido" bigint, "p_metodo" character varying, "p_valor" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."resumo_carrinho"("p_id_carrinho" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resumo_carrinho"("p_id_carrinho" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."resumo_carrinho"("p_id_carrinho" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."validar_carrinho_checkout"("p_id_carrinho" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validar_carrinho_checkout"("p_id_carrinho" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."validar_carrinho_checkout"("p_id_carrinho" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."validar_cupom"("p_codigo" character varying, "p_valor_compra" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validar_cupom"("p_codigo" character varying, "p_valor_compra" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."validar_cupom"("p_codigo" character varying, "p_valor_compra" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."validar_estoque_carrinho"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validar_estoque_carrinho"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."validar_transicao_rastreamento"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validar_transicao_rastreamento"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validar_transicao_rastreamento"() TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."assinatura" TO "authenticated";
GRANT ALL ON TABLE "public"."assinatura" TO "service_role";



GRANT ALL ON SEQUENCE "public"."assinatura_id_assinatura_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."assinatura_id_assinatura_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."assinatura_id_assinatura_seq" TO "service_role";



GRANT ALL ON TABLE "public"."avaliacao_produto" TO "anon";
GRANT ALL ON TABLE "public"."avaliacao_produto" TO "authenticated";
GRANT ALL ON TABLE "public"."avaliacao_produto" TO "service_role";



GRANT ALL ON SEQUENCE "public"."avaliacao_produto_id_avaliacao_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."avaliacao_produto_id_avaliacao_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."avaliacao_produto_id_avaliacao_seq" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."beneficio_assinatura" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."beneficio_assinatura" TO "authenticated";
GRANT ALL ON TABLE "public"."beneficio_assinatura" TO "service_role";



GRANT ALL ON SEQUENCE "public"."beneficio_assinatura_id_beneficio_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."beneficio_assinatura_id_beneficio_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."beneficio_assinatura_id_beneficio_seq" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."carrinho" TO "anon";
GRANT ALL ON TABLE "public"."carrinho" TO "authenticated";
GRANT ALL ON TABLE "public"."carrinho" TO "service_role";



GRANT ALL ON SEQUENCE "public"."carrinho_id_carrinho_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."carrinho_id_carrinho_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."carrinho_id_carrinho_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."categoria_id_categoria_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."categoria_id_categoria_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."categoria_id_categoria_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cupom" TO "anon";
GRANT ALL ON TABLE "public"."cupom" TO "authenticated";
GRANT ALL ON TABLE "public"."cupom" TO "service_role";



GRANT ALL ON TABLE "public"."cupom_categoria" TO "anon";
GRANT ALL ON TABLE "public"."cupom_categoria" TO "authenticated";
GRANT ALL ON TABLE "public"."cupom_categoria" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cupom_id_cupom_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cupom_id_cupom_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cupom_id_cupom_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cupom_produto" TO "anon";
GRANT ALL ON TABLE "public"."cupom_produto" TO "authenticated";
GRANT ALL ON TABLE "public"."cupom_produto" TO "service_role";



GRANT ALL ON TABLE "public"."endereco" TO "anon";
GRANT ALL ON TABLE "public"."endereco" TO "authenticated";
GRANT ALL ON TABLE "public"."endereco" TO "service_role";



GRANT ALL ON SEQUENCE "public"."endereco_id_endereco_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."endereco_id_endereco_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."endereco_id_endereco_seq" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."estoque" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."estoque" TO "authenticated";
GRANT ALL ON TABLE "public"."estoque" TO "service_role";



GRANT ALL ON SEQUENCE "public"."estoque_id_estoque_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."estoque_id_estoque_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."estoque_id_estoque_seq" TO "service_role";



GRANT ALL ON TABLE "public"."favorito" TO "anon";
GRANT ALL ON TABLE "public"."favorito" TO "authenticated";
GRANT ALL ON TABLE "public"."favorito" TO "service_role";



GRANT ALL ON SEQUENCE "public"."favorito_id_favorito_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."favorito_id_favorito_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."favorito_id_favorito_seq" TO "service_role";



GRANT ALL ON TABLE "public"."historico_status_pedido" TO "anon";
GRANT ALL ON TABLE "public"."historico_status_pedido" TO "authenticated";
GRANT ALL ON TABLE "public"."historico_status_pedido" TO "service_role";



GRANT ALL ON SEQUENCE "public"."historico_status_pedido_id_historico_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."historico_status_pedido_id_historico_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."historico_status_pedido_id_historico_seq" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."item_carrinho" TO "anon";
GRANT ALL ON TABLE "public"."item_carrinho" TO "authenticated";
GRANT ALL ON TABLE "public"."item_carrinho" TO "service_role";



GRANT ALL ON SEQUENCE "public"."item_carrinho_id_item_carrinho_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."item_carrinho_id_item_carrinho_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."item_carrinho_id_item_carrinho_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."item_pedido_id_item_pedido_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."item_pedido_id_item_pedido_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."item_pedido_id_item_pedido_seq" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."notificacao_assinante" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."notificacao_assinante" TO "authenticated";
GRANT ALL ON TABLE "public"."notificacao_assinante" TO "service_role";



GRANT UPDATE("lida") ON TABLE "public"."notificacao_assinante" TO "authenticated";



GRANT UPDATE("data_leitura") ON TABLE "public"."notificacao_assinante" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."notificacao_assinante_id_notificacao_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."notificacao_assinante_id_notificacao_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notificacao_assinante_id_notificacao_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pagamento_id_pagamento_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pagamento_id_pagamento_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pagamento_id_pagamento_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pedido_id_pedido_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pedido_id_pedido_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pedido_id_pedido_seq" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."perfil" TO "anon";
GRANT ALL ON TABLE "public"."perfil" TO "authenticated";
GRANT ALL ON TABLE "public"."perfil" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."plano_assinatura" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."plano_assinatura" TO "authenticated";
GRANT ALL ON TABLE "public"."plano_assinatura" TO "service_role";



GRANT ALL ON SEQUENCE "public"."plano_assinatura_id_plano_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."plano_assinatura_id_plano_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."plano_assinatura_id_plano_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."produto_id_produto_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."produto_id_produto_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."produto_id_produto_seq" TO "service_role";



GRANT ALL ON TABLE "public"."rastreamento_pedido" TO "anon";
GRANT ALL ON TABLE "public"."rastreamento_pedido" TO "authenticated";
GRANT ALL ON TABLE "public"."rastreamento_pedido" TO "service_role";



GRANT ALL ON SEQUENCE "public"."rastreamento_pedido_id_rastreamento_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."rastreamento_pedido_id_rastreamento_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."rastreamento_pedido_id_rastreamento_seq" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







