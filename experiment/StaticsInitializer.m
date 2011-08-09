classdef StaticsInitializer < handle
%___________________________________________________________________________________________________ 
%===================================================================================================
    properties (Constant = true, Transient = true) %                     C O N S T A N T         [P]
        CELLVAR = 0;
        FLUXL   = 1;
        FLUXR   = 2;
        FLUXALL = 3;
    end%CONSTANT
        
%===================================================================================================
    properties (SetAccess = public, GetAccess = public) %                           P U B L I C  [P]

        indexSet; % Arrays in indices to set statically            Cell[N]
        valueSet; % Arrays of values to set statically             Cell[N]
        coeffSet; % Arrays of coefficients to set [must match dimensions of corresponding value set]

        arrayStatics; % Cell array with one cell per simulation var Cell[5];
        % WARNING: THIS MUST BE THE SAME SIZE AS THE NUMBER OF SIMULATION VARIABLES

    end %PUBLIC

%===================================================================================================
    properties (SetAccess = protected, GetAccess = protected) %                P R O T E C T E D [P]

        readyForReadout; % Set if prepareStaticsForSimulation() has been called and
                         % no new associations have been created since

    end %PROTECTED
        
%===================================================================================================
    methods %                                                                     G E T / S E T  [M]

    end%GET/SET
        
%===================================================================================================
    methods (Access = public) %                                                     P U B L I C  [M]

        function obj = StaticsInitializer()
            obj.arrayStatics = cell(8,1); % Create one arrayStatics for every variable
            for x = 1:8
                obj.arrayStatics{x} = struct('arrayField',[], 'indexId',[], 'valueId',[], 'coeffId',[]);
                % Create structs to associate pairs of index sets and values with the primary & flux
                % arrays of each simulation variable
            end
        end

        function [indices values coeffs] = staticsForVariable(obj, varId, component, fieldId)
            indices = [];
            values = [];
            coeffs = [];

            if ~obj.readyForReadout; obj.prepareStaticsForSimulation(); end

            partmap = obj.mapVaridToIdx(varId, component);
            if partmap == 0; return; end

            AS = obj.arrayStatics{partmap};

            for x = 1:numel(AS.arrayField) % For each static defined for this variable
                if AS.arrayField(x) == fieldId % If it applies to the requested field
                    newIdx   = obj.indexSet{AS.indexId(x)};
                    newVal   = obj.valueSet{AS.valueId(x)};
                    if AS.coeffId(x) == 0
                        newCoeff = 1;
                    else
                        newCoeff = obj.coeffSet{AS.coeffId(x)};
                    end

                    % Expand array-scalar pairs to array-array pairs; This can be done
                    if numel(newVal) == 1; newVal   = newVal   * ones(size(newIdx,1),1); end
                    if numel(newCoeff)==1; newCoeff = newCoeff * ones(size(newIdx,1),1); end

                    % Fail if nonequally sized arrays are paired; This cannot be done
                    if size(newVal,1) ~= size(newIdx,1)
                    error(sprintf('Unrecoverable error preparing statics; numel(index set %i) = %i but numel(value set %i) = %i.\n', x, size(obj.indexSet{x},1), x, numel(obj.valueSet{x})));
                    end

                    indices = [indices; newIdx]; % cat indices
                    values  = [values ; newVal]; % cat values
                    coeffs  = [coeffs ; newCoeff]; % cat fade coefficients
                end
            end

        end

        % This function prepares statics for injection into array statics by reshaping for concatenation
        function prepareStaticsForSimulation(obj)
            % Reshape them to be Nx1 arrays so we can cat using [u; v]
            for x = 1:numel(obj.indexSet)
                % Reshape them to be Nx1
%                obj.indexSet{x} = reshape(obj.indexSet{x}, [numel(obj.indexSet{x}) 1]);
%                obj.valueSet{x} = reshape(obj.valueSet{x}, [numel(obj.valueSet{x}) 1]);
            end

            obj.readyForReadout = 1;

        end

        % Adds a pair of statics
        function addStatics(obj, indices, values, coeffs)
            obj.indexSet{end+1} = indices;
            obj.valueSet{end+1} = values;
            if nargin == 3
                obj.coeffSet{end+1} = 1;
            else
                obj.coeffSet{end+1} = coeffs;
            end
        end

        function associateStatics(obj, varID, component, fieldID, indexNum, valueNum, coeffNum)
            vmap = obj.mapVaridToIdx(varID, component);

            obj.arrayStatics{vmap}.arrayField(end+1) = fieldID;
            obj.arrayStatics{vmap}.indexId(end+1)    = indexNum;
            obj.arrayStatics{vmap}.valueId(end+1)    = valueNum;
            if nargin == 6
                obj.arrayStatics{vmap}.coeffId(end+1) = 0;
            else
                obj.arrayStatics{vmap}.coeffId(end+1)    = coeffNum;
            end

            obj.readyForReadout = 0;
        end

    end%PUBLIC
        
%===================================================================================================        
    methods (Access = protected) %                                          P R O T E C T E D    [M]

    end%PROTECTED
                
%===================================================================================================        
    methods (Static = true) %                                                     S T A T I C    [M]

        function result = mapVaridToIdx(varId, component)
            if strcmp(varId,ENUM.MASS); result = 1; return; end
            if strcmp(varId,ENUM.ENER); result = 2; return; end
            if strcmp(varId,ENUM.MOM); result = 2+component; return; end % 3-4-5
            if strcmp(varId,ENUM.MAG); result = 5+component; return; end % 6-7-8

            result = 0;
            return;
        end

    end%PROTECTED
        
end%CLASS
