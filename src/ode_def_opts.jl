function ode_def_opts(name::Symbol,opts::Dict{Symbol,Bool},ex::Expr,params...;M=I,depvar=:t)
  # depvar is the dependent variable. Defaults to t
  # M is the mass matrix in RosW, must be a constant!
  origex = copy(ex) # Save the original expression

  if !(eltype(params) <: Symbol)
    error("The syntax for ParameterizedFunctions has changed. Simply list the parameters at the end, i.e. `a b c d`, instead of `a=5.0 b=>3.0 ...`. Parameters are defined in the problem type. See the documentation for more information.")
  end
  params = [params...]

  ## Build independent variable dictionary
  indvar_dict,syms = build_indvar_dict(ex,depvar)
  ####
  # Build the Expressions

  # Run find replace to make the function expression
  symex = copy(ex) # Different expression for symbolic computations
  ode_findreplace(ex,symex,indvar_dict,params)
  push!(ex.args,nothing) # Make the return void
  fex = ex # Save this expression as the expression for the call

  # Parameter-Explicit Functions
  pex = copy(origex) # Build it from the original expression
  # Parameter find/replace
  ode_findreplace(pex,copy(ex),indvar_dict,params;params_from_function=false)

  # Vectorized Functions
  vector_ex = copy(origex) # Build it from the original expression
  ode_findreplace(vector_ex,copy(origex),indvar_dict,params;
                  vectorized_form=true,vectorized_returns=:slice)
  vector_ex_return = copy(origex) # Build it from the original expression
  ode_findreplace(vector_ex_return,copy(origex),indvar_dict,params;
                  vectorized_form=true,vectorized_returns=:vals)
  dus = [Symbol("internal_var___du$i") for i in 1:length(keys(indvar_dict))] # TODO: vectorized forms need @. to work
  push!(vector_ex_return.args,:(hcat($(dus...)))) # Make the return void

  ######
  # Build the Functions

  # Get the component functions
  funcs = build_component_funcs(symex)

  numsyms = length(indvar_dict)
  numparams = length(params)

  # Parameter Functions
  paramfuncs = Vector{Vector{Expr}}(undef, numparams)
  for i in 1:numparams
    tmp_pfunc = Vector{Expr}(length(funcs))
    for j in eachindex(funcs)
      tmp_pfunc[j] = copy(funcs[j])
    end
    paramfuncs[i] = tmp_pfunc
  end
  pfuncs = build_p_funcs(paramfuncs,indvar_dict,params)

  # Symbolic Setup
  symfuncs = Vector{SymEngine.Basic}(undef, 0)
  symtgrad = Vector{SymEngine.Basic}(undef, 0)
  symjac   = Matrix{SymEngine.Basic}(undef, 0,0)
  expjac   = Matrix{SymEngine.Basic}(undef, 0,0)
  invjac   = Matrix{SymEngine.Basic}(undef, 0,0)
  symhes   = Matrix{SymEngine.Basic}(undef, 0,0)
  invhes   = Matrix{SymEngine.Basic}(undef, 0,0)
  syminvW  = Matrix{SymEngine.Basic}(undef, 0,0)
  syminvW_t= Matrix{SymEngine.Basic}(undef, 0,0)
  param_symjac = Matrix{SymEngine.Basic}(undef, 0,0)
  tgradex = :(error("t-gradient Does Not Exist"))
  tgrad_exists = false
  Jex = :(error("Jacobian Does Not Exist"))
  jac_exists = false
  expJex = :(error("Exponential Jacobian Does Not Exist"))
  expjac_exists = false
  invJex = :(error("Inverse Jacobian Does Not Exist"))
  invjac_exists = false
  invWex = :(error("Inverse Rosenbrock-W Does Not Exist"))
  invW_exists = false
  invWex_t = :(error("Inverse Rosenbrock-W Transformed Does Not Exist"))
  invW__t_exists = false
  Hex = :(error("Hessian Does Not Exist"))
  hes_exists = false
  invHex = :(error("Inverse Hessian Does Not Exist"))
  invhes_exists = false
  param_Jex = :(error("Parameter Jacobian Does Not Exist"))
  param_jac_exists = false

  d_pfuncs = Vector{Expr}(undef, 0)
  param_symjac = Matrix{SymEngine.Basic}(numsyms,numparams)
  pderiv_exists = false

  if opts[:build_tgrad] || opts[:build_jac] || opts[:build_dpfuncs]
    try #do symbolic calculations

      # Set Internal γ, used as a symbol for letting users pass an extra scalar
      γ = symbols("internal_γ")

      # Build the symbolic functions

      symfuncs = [SymEngine.Basic(f) for f in funcs]

      if opts[:build_tgrad]
        try
          symtgrad = [diff(f,depvar) for f in symfuncs]
          tgrad_exists = true
          tgradex = build_tgrad_func(symtgrad,indvar_dict,params)
        catch err
          warn("Time Derivative Gradient could not be built")
        end
      end

      if opts[:build_jac]
        try #Jacobians and Hessian
          # Build the Jacobian Matrix of SymEngine Expressions
          symjac = Matrix{SymEngine.Basic}(numsyms,numsyms)
          for i in eachindex(funcs)
            for j in eachindex(syms)
              symjac[i,j] = diff(symfuncs[i],syms[j])
            end
          end

          # Build the Julia function
          Jex = build_jac_func(symjac,indvar_dict,params)
          bad_derivative(Jex)
          jac_exists = true

          if opts[:build_expjac]
            try
              expjac = expm(γ*symjac) # This does not work, which is why disabled
              expJex = build_jac_func(expjac,indvar_dict,params)
              bad_derivative(expJex)
              expjac_exists = true
            catch
              warn("Jacobian could not exponentiate")
            end
          end

          if opts[:build_invjac]
            try # Jacobian Inverse
              invjac = inv(symjac)
              invJex = build_jac_func(invjac,indvar_dict,params)
              bad_derivative(invJex)
              invjac_exists = true
            catch err
              warn("Jacobian could not invert")
            end
          end
          if opts[:build_invW]
            try # Rosenbrock-W Inverse
              syminvW = inv(M - γ*symjac)
              syminvW_t = inv(M/γ - symjac)
              invWex = build_jac_func(syminvW,indvar_dict,params)
              bad_derivative(invWex)
              invW_exists = true
              invWex_t = build_jac_func(syminvW_t,indvar_dict,params)
              bad_derivative(invWex_t)
              invW_t_exists = true
            catch err
              warn("Rosenbrock-W could not invert")
            end
          end
          if opts[:build_hes]
            try # Hessian
              symhes = Matrix{SymEngine.Basic}(numsyms,numsyms)
              for i in eachindex(funcs), j in eachindex(syms)
                symhes[i,j] = diff(symjac[i,j],syms[j])
              end
              # Build the Julia function
              Hex = build_jac_func(symhes,indvar_dict,params)
              bad_derivative(Hex)
              hes_exists = true
              if opts[:build_invhes]
                try # Hessian Inverse
                  invhes = inv(symhes)
                  invHex = build_jac_func(invhes,indvar_dict,params)
                  bad_derivative(invHex)
                  invhes_exists = true
                catch err
                  warn("Hessian could not invert")
                end
              end
            end
          end
        catch err
          warn("Failed to build the Jacobian. This means the Hessian is not built as well.")
        end
      end # End Jacobian tree

      if opts[:build_dpfuncs]
        try # Parameter Gradients
          d_paramfuncs  = Vector{Vector{Expr}}(numparams)
          for i in eachindex(params)
            tmp_dpfunc = Vector{Expr}(length(funcs))
            for j in eachindex(funcs)
              funcex = funcs[j]
              d_curr = diff(symfuncs[j],params[i])
              param_symjac[j,i] = d_curr
              symfunc_str = parse(string(d_curr))
              if typeof(symfunc_str) <: Number
                tmp_dpfunc[j] = :($symfunc_str*1)
              elseif typeof(symfunc_str) <: Symbol
                tmp_dpfunc[j] = :($symfunc_str*1)
              else
                tmp_dpfunc[j] = symfunc_str
              end
            end
            d_paramfuncs[i] = tmp_dpfunc
          end
          d_pfuncs = build_p_funcs(d_paramfuncs,indvar_dict,params)
          pderiv_exists = true

          # Now build the parameter Jacobian
          param_symjac_ex = Matrix{Expr}(numsyms,numparams)
          for i in 1:numparams
            param_symjac_ex[:,i] = d_paramfuncs[i]
          end

          param_Jex = build_jac_func(param_symjac_ex,indvar_dict,params,params_from_function=false)
          param_jac_exists = true
        catch err
          println(err)
          warn("Failed to build the parameter derivatives.")
        end
      end
    catch err
      warn("Symbolic calculations could not initiate. Likely there's a function which is not differentiable by SymEngine.")
    end
  end

  # Build the type
  exprs = Vector{Expr}(undef, 0)

  typeex,constructorex = maketype(name,params,origex,funcs,syms,fex,pex=pex,
               vector_ex = vector_ex,vector_ex_return = vector_ex_return,
               symfuncs=symfuncs,symtgrad=symtgrad,tgradex=tgradex,
               symjac=symjac,Jex=Jex,expjac=expjac,expJex=expJex,invjac=invjac,
               invWex=invWex,invWex_t=invWex_t,syminvW=syminvW,
               syminvW_t=syminvW_t,invJex=invJex,symhes=symhes,invhes=invhes,Hex=Hex,
               invHex=invHex,params=params,
               pfuncs=pfuncs,d_pfuncs=d_pfuncs,
               param_symjac=param_symjac,param_Jex=param_Jex)

  push!(exprs,typeex)
  push!(exprs,constructorex)



  #=
  # Value Dispatches for the Parameters
  for i in 1:length(params)
    param = Symbol(params[i])
    param_func = pfuncs[i]
    param_valtype = Val{param}
    overloadex = :(((f::$name))(::Type{$param_valtype},t,internal_var___u,$param,internal_var___du) = $param_func) |> esc
    push!(exprs,overloadex)
  end
  =#

  # Build the Function
  overloadex = :(((f::$name))(internal_var___du,internal_var___u,internal_var___p,t::Number) = $pex) |> esc
  push!(exprs,overloadex)

  # Add a method which allocates the `du` and returns it instead of being inplace
  overloadex = :(((f::$name))(u,p,t::Number) = (du=similar(u); f(du,u,p,t); du)) |> esc
  push!(exprs,overloadex)

  #=
  # Build the Vectorized functions
  overloadex = :(((internal_var___p::$name))(::Type{Val{:vec}},t::Number,internal_var___u,internal_var___du) = $vector_ex) |> esc
  push!(exprs,overloadex)

  # Build the Vectorized functions
  overloadex = :(((internal_var___p::$name))(::Type{Val{:vec}},t::Number,internal_var___u) = $vector_ex_return) |> esc
  push!(exprs,overloadex)

  overloadex = :(((internal_var___p::$name))(::Type{Val{:vec}},t::Number,u) = (du=similar(u); p(t,internal_var___u,du); du)) |> esc
  push!(exprs,overloadex)
  =#

  # Value Dispatches for the Parameter Derivatives
  #=
  if pderiv_exists
    for i in 1:length(params)
      param = Symbol(params[i])
      param_func = d_pfuncs[i]
      param_valtype = Val{param}
      overloadex = :(((internal_var___p::$name))(::Type{Val{:deriv}},::Type{$param_valtype},t,internal_var___u,$param,internal_var___du) = $param_func) |> esc
      push!(exprs,overloadex)
    end
  end
  =#

  # Add the t gradient
  if tgrad_exists
    overloadex = :(((f::$name))(::Type{Val{:tgrad}},internal_var___grad,internal_var___u,internal_var___p,t) = $tgradex) |> esc
    push!(exprs,overloadex)
  end

  # Add the Jacobian
  if jac_exists
    overloadex = :(((f::$name))(::Type{Val{:jac}},internal_var___J,internal_var___u,internal_var___p,t) = $Jex) |> esc
    push!(exprs,overloadex)
    overloadex = :(((f::$name))(::Type{Val{:jac}},u,p,t::Number) = (J=similar(u, (length(u), length(u))); f(Val{:jac},J,u,p,t); J)) |> esc
    push!(exprs,overloadex)
  end

  #=
  # Add the Exponential Jacobian
  if expjac_exists
    overloadex = :(((internal_var___p::$name))(::Type{Val{:expjac}},t,internal_var___u,internal_γ,internal_var___J) = $expJex) |> esc
    push!(exprs,overloadex)
  end
  =#

  # Add the Inverse Jacobian
  if invjac_exists
    overloadex = :(((f::$name))(::Type{Val{:invjac}},internal_var___J,internal_var___u,internal_var___p,t) = $invJex) |> esc
    push!(exprs,overloadex)
  end
  # Add the Inverse Rosenbrock-W
  if invW_exists
    overloadex = :(((f::$name))(::Type{Val{:invW}},internal_var___J,internal_var___u,internal_var___p,internal_γ,t) = $invWex) |> esc
    push!(exprs,overloadex)
  end
  # Add the Inverse Rosenbrock-W Transformed
  if invW_exists
    overloadex = :(((f::$name))(::Type{Val{:invW_t}},internal_var___J,internal_var___u,internal_var___p,internal_γ,t) = $invWex_t) |> esc
    push!(exprs,overloadex)
  end
  #=
  # Add the Hessian
  if hes_exists
    overloadex = :(((internal_var___p::$name))(::Type{Val{:hes}},t,internal_var___u,internal_var___J) = $Hex) |> esc
    push!(exprs,overloadex)
  end
  # Add the Inverse Hessian
  if invhes_exists
    overloadex = :(((internal_var___p::$name))(::Type{Val{:invhes}},t,internal_var___u,internal_var___J) = $invHex) |> esc
    push!(exprs,overloadex)
  end
  =#

  # Add Parameter Jacobian
  if param_jac_exists
    overloadex = :(((f::$name))(::Type{Val{:paramjac}},internal_var___J,internal_var___u,internal_var___p,t) = $param_Jex) |> esc
    push!(exprs,overloadex)
  end

  # Return the type from the default consturctor
  def_const_ex = :(($name)()) |> esc
  push!(exprs,def_const_ex)
  expr_arr_to_block(exprs)
end
