

# forward-mode evaluation of an expression tree
# tree is represented as Vector{NodeData} and adjacency matrix from adjmat()
# assumes values of expressions have already been computed
# partials_storage[k] is the partial derivative of nd[k].parent with respect to the value
# of node k. It's efficient to compute this at the same time as the value of the parent.
# Since we use it in reverse mode and in dual forward mode.
# Note that partials_storage makes a subtle assumption that we have a tree instead of
# a general DAG. If we have a DAG, then need to associate storage with each edge of the DAG.
function forward_eval{T}(storage::Vector{T},partials_storage::Vector{T},nd::Vector{NodeData},adj,const_values,parameter_values,x_values::Vector{T},subexpression_values)

    @assert length(storage) >= length(nd)
    @assert length(partials_storage) >= length(nd)

    # nd is already in order such that parents always appear before children
    # so a backwards pass through nd is a forward pass through the tree

    children_arr = rowvals(adj)

    for k in length(nd):-1:1
        # compute the value of node k
        @inbounds nod = nd[k]
        partials_storage[k] = zero(T)
        if nod.nodetype == VARIABLE
            @inbounds storage[k] = x_values[nod.index]
        elseif nod.nodetype == VALUE
            @inbounds storage[k] = const_values[nod.index]
        elseif nod.nodetype == SUBEXPRESSION
            @inbounds storage[k] = subexpression_values[nod.index]
        elseif nod.nodetype == PARAMETER
            @inbounds storage[k] = parameter_values[nod.index]
        elseif nod.nodetype == CALL
            op = nod.index
            @inbounds children_idx = nzrange(adj,k)
            #@show children_idx
            n_children = length(children_idx)
            if op == 1 # :+
                tmp_sum = zero(T)
                # sum over children
                for c_idx in children_idx
                    @inbounds ix = children_arr[c_idx]
                    @inbounds partials_storage[ix] = one(T)
                    @inbounds tmp_sum += storage[ix]
                end
                storage[k] = tmp_sum
            elseif op == 2 # :-
                child1 = first(children_idx)
                @assert n_children == 2
                @inbounds ix1 = children_arr[child1]
                @inbounds ix2 = children_arr[child1+1]
                @inbounds tmp_sub = storage[ix1]
                @inbounds tmp_sub -= storage[ix2]
                @inbounds partials_storage[ix1] = one(T)
                @inbounds partials_storage[ix2] = -one(T)
                storage[k] = tmp_sub
            elseif op == 3 # :*
                tmp_prod = one(T)
                for c_idx in children_idx
                    @inbounds tmp_prod *= storage[children_arr[c_idx]]
                end
                if tmp_prod == zero(T) # inefficient
                    for c_idx in children_idx
                        prod_others = one(T)
                        for c_idx2 in children_idx
                            (c_idx == c_idx2) && continue
                            prod_others *= storage[children_arr[c_idx2]]
                        end
                        partials_storage[children_arr[c_idx]] = prod_others
                    end
                else
                    for c_idx in children_idx
                        ix = children_arr[c_idx]
                        partials_storage[ix] = tmp_prod/storage[ix]
                    end
                end
                @inbounds storage[k] = tmp_prod
            elseif op == 4 # :^
                @assert n_children == 2
                idx1 = first(children_idx)
                idx2 = last(children_idx)
                @inbounds ix1 = children_arr[idx1]
                @inbounds ix2 = children_arr[idx2]
                @inbounds base = storage[ix1]
                @inbounds exponent = storage[ix2]
                if exponent == 2
                    @inbounds storage[k] = base*base
                    @inbounds partials_storage[ix1] = 2*base
                else
                    storage[k] = pow(base,exponent)
                    partials_storage[ix1] = exponent*pow(base,exponent-1)
                end
                partials_storage[ix2] = storage[k]*log(base)
            elseif op == 5 # :/
                @assert n_children == 2
                idx1 = first(children_idx)
                idx2 = last(children_idx)
                @inbounds ix1 = children_arr[idx1]
                @inbounds ix2 = children_arr[idx2]
                @inbounds numerator = storage[ix1]
                @inbounds denominator = storage[ix2]
                recip_denominator = 1/denominator
                @inbounds partials_storage[ix1] = recip_denominator
                partials_storage[ix2] = -numerator*recip_denominator*recip_denominator
                storage[k] = numerator*recip_denominator
            elseif op == 6 # ifelse
                @assert n_children == 3
                idx1 = first(children_idx)
                @inbounds condition = storage[children_arr[idx1]]
                @inbounds lhs = storage[children_arr[idx1+1]]
                @inbounds rhs = storage[children_arr[idx1+2]]
                @inbounds partials_storage[children_arr[idx1+1]] = condition == 1
                @inbounds partials_storage[children_arr[idx1+2]] = !(condition == 1)
                storage[k] = ifelse(condition == 1, lhs, rhs)
            else
                error("Unsupported operation $(operators[op])")
            end
        elseif nod.nodetype == CALLUNIVAR # univariate function
            op = nod.index
            @inbounds child_idx = children_arr[adj.colptr[k]]
            #@assert child_idx == children_arr[first(nzrange(adj,k))]
            child_val = storage[child_idx]
            fval, fprimeval = eval_univariate(op, child_val)
            @inbounds partials_storage[child_idx] = fprimeval
            @inbounds storage[k] = fval
        elseif nod.nodetype == COMPARISON
            op = nod.index

            @inbounds children_idx = nzrange(adj,k)
            n_children = length(children_idx)
            result = true
            for r in 1:n_children-1
                partials_storage[children_arr[children_idx[r]]] = zero(T)
                cval_lhs = storage[children_arr[children_idx[r]]]
                cval_rhs = storage[children_arr[children_idx[r+1]]]
                if op == 1
                    result &= cval_lhs <= cval_rhs
                elseif op == 2
                    result &= cval_lhs == cval_rhs
                elseif op == 3
                    result &= cval_lhs >= cval_rhs
                elseif op == 4
                    result &= cval_lhs < cval_rhs
                elseif op == 5
                    result &= cval_lhs > cval_rhs
                end
            end
            partials_storage[children_arr[children_idx[n_children]]] = zero(T)
            storage[k] = result
        elseif nod.nodetype == LOGIC
            op = nod.index
            @inbounds children_idx = nzrange(adj,k)
            # boolean values are stored as floats
            partials_storage[children_arr[first(children_idx)]] = zero(T)
            partials_storage[children_arr[last(children_idx)]] = zero(T)
            cval_lhs = (storage[children_arr[first(children_idx)]] == 1)
            cval_rhs = (storage[children_arr[last(children_idx)]] == 1)
            if op == 1
                storage[k] = cval_lhs && cval_rhs
            elseif op == 2
                storage[k] = cval_lhs || cval_rhs
            end
        end

    end
    #@show storage

    return storage[1]

end

export forward_eval

@inline gradnum(x,ϵval) = ForwardDiff.GradientNumber(x,ϵval.data)

# Evaluate directional derivatives of an expression tree.
# This is equivalent to evaluating the expression tree using DualNumbers or ForwardDiff,
# but instead we keep the storage for the epsilon components separate so that we don't
# need to recompute the real components.
# Computes partials_storage_ϵ as well
# We assume that forward_eval has already been called.
function forward_eval_ϵ{N,T}(storage::Vector{T},storage_ϵ::Vector{ForwardDiff.PartialsTup{N,T}},partials_storage::Vector{T},partials_storage_ϵ::Vector{ForwardDiff.PartialsTup{N,T}},nd::Vector{NodeData},adj,x_values_ϵ,subexpression_values_ϵ)

    @assert length(storage_ϵ) >= length(nd)
    @assert length(partials_storage_ϵ) >= length(nd)

    zero_ϵ = ForwardDiff.zero_partials(NTuple{N,T},N)

    # nd is already in order such that parents always appear before children
    # so a backwards pass through nd is a forward pass through the tree

    children_arr = rowvals(adj)

    for k in length(nd):-1:1
        # compute the value of node k
        @inbounds nod = nd[k]
        partials_storage_ϵ[k] = zero_ϵ
        if nod.nodetype == VARIABLE
            @inbounds storage_ϵ[k] = x_values_ϵ[nod.index]
        elseif nod.nodetype == VALUE
            @inbounds storage_ϵ[k] = zero_ϵ
        elseif nod.nodetype == SUBEXPRESSION
            @inbounds storage_ϵ[k] = subexpression_values_ϵ[nod.index]
        elseif nod.nodetype == PARAMETER
            @inbounds storage_ϵ[k] = zero_ϵ
        else
            ϵtmp = zero_ϵ
            @inbounds children_idx = nzrange(adj,k)
            for c_idx in children_idx
                ix = children_arr[c_idx]
                ϵtmp += storage_ϵ[ix]*partials_storage[ix]
            end
            storage_ϵ[k] = ϵtmp

            if nod.nodetype == CALL
                op = nod.index
                n_children = length(children_idx)
                if op == 3 # :*
                    # Lazy approach for now
                    tmp_prod = one(ForwardDiff.GradientNumber{N,T,NTuple{N,T}})
                    for c_idx in children_idx
                        ix = children_arr[c_idx]
                        gnum = gradnum(storage[ix],storage_ϵ[ix])
                        tmp_prod *= gnum
                    end
                    if ForwardDiff.value(tmp_prod) == zero(T) # inefficient
                        for c_idx in children_idx
                            prod_others = one(ForwardDiff.GradientNumber{N,T,NTuple{N,T}})
                            for c_idx2 in children_idx
                                (c_idx == c_idx2) && continue
                                ix = children_arr[c_idx2]
                                gnum = gradnum(storage[ix],storage_ϵ[ix])
                                prod_others *= gnum
                            end
                            partials_storage_ϵ[children_arr[c_idx]] = ForwardDiff.partials(prod_others)
                        end
                    else
                        for c_idx in children_idx
                            ix = children_arr[c_idx]
                            prod_others = tmp_prod/gradnum(storage[ix],storage_ϵ[ix])
                            partials_storage_ϵ[ix] = ForwardDiff.partials(prod_others)
                        end
                    end
                elseif op == 4 # :^
                    @assert n_children == 2
                    idx1 = first(children_idx)
                    idx2 = last(children_idx)
                    @inbounds ix1 = children_arr[idx1]
                    @inbounds ix2 = children_arr[idx2]
                    @inbounds base = storage[ix1]
                    @inbounds base_ϵ = storage_ϵ[ix1]
                    @inbounds exponent = storage[ix2]
                    @inbounds exponent_ϵ = storage_ϵ[ix2]
                    base_gnum = gradnum(base,base_ϵ)
                    exponent_gnum = gradnum(exponent,exponent_ϵ)
                    if exponent == 2
                        partials_storage_ϵ[ix1] = 2*base_ϵ
                    else
                        partials_storage_ϵ[ix1] = ForwardDiff.partials(exponent_gnum*pow(base_gnum,exponent_gnum-1))
                    end
                    result_gnum = gradnum(storage[k],storage_ϵ[k])
                    partials_storage_ϵ[ix2] = ForwardDiff.partials(result_gnum*log(base_gnum))
                elseif op == 5 # :/
                    @assert n_children == 2
                    idx1 = first(children_idx)
                    idx2 = last(children_idx)
                    @inbounds ix1 = children_arr[idx1]
                    @inbounds ix2 = children_arr[idx2]
                    @inbounds numerator = storage[ix1]
                    @inbounds numerator_ϵ = storage_ϵ[ix1]
                    @inbounds denominator = storage[ix2]
                    @inbounds denominator_ϵ = storage_ϵ[ix2]
                    recip_denominator = 1/gradnum(denominator,denominator_ϵ)
                    partials_storage_ϵ[ix1] = ForwardDiff.partials(recip_denominator)
                    partials_storage_ϵ[ix2] = ForwardDiff.partials(-gradnum(numerator,numerator_ϵ)*recip_denominator*recip_denominator)
                end
            elseif nod.nodetype == CALLUNIVAR # univariate function
                op = nod.index
                @inbounds child_idx = children_arr[adj.colptr[k]]
                child_val = storage[child_idx]
                fprimeprime = eval_univariate_2nd_deriv(op, child_val,storage[k])
                partials_storage_ϵ[child_idx] = fprimeprime*storage_ϵ[child_idx]
            end
        end

    end

    return storage_ϵ[1]

end

export forward_eval_ϵ


switchblock = Expr(:block)
for i = 1:length(univariate_operators)
    op = univariate_operators[i]
    deriv_expr = univariate_operator_deriv[i]
	ex = :(return $op(x), $deriv_expr::T)
    push!(switchblock.args,i,ex)
end
switchexpr = Expr(:macrocall, Expr(:.,:Lazy,quot(symbol("@switch"))), :operator_id,switchblock)

@eval @inline function eval_univariate{T}(operator_id,x::T)
    $switchexpr
end

# TODO: optimize sin/cos/exp
switchblock = Expr(:block)
for i = 1:length(univariate_operators)
    op = univariate_operators[i]
    if op == :asec || op == :acsc || op == :asecd || op == :acscd || op == :acsch || op == :trigamma
        # there's an abs in the derivative that Calculus can't symbolically differentiate
        continue
    end
    if i in 1:3 # :+, :-, :abs
        deriv_expr = :(zero(T))
    else
        deriv_expr = Calculus.differentiate(univariate_operator_deriv[i],:x)
    end
	ex = :(return $deriv_expr::T)
    push!(switchblock.args,i,ex)
end
switchexpr = Expr(:macrocall, Expr(:.,:Lazy,quot(symbol("@switch"))), :operator_id,switchblock)

@eval @inline function eval_univariate_2nd_deriv{T}(operator_id,x::T,fval::T)
    $switchexpr
end
