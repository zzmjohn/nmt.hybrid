%%%
%
% Perform softmax prediction and backprop.
%
% From the point of view of the model graph structure, this method handles
% all subgraphs from the LSTM hiddent state to the softmax predictions,
% i.e., there can be other intermediate layers for the case of positional
% models, attention functions, and softmax compression.
%
% Thang Luong @ 2015, <lmthang@stanford.edu>
%
%%%
function [costs, softmaxGrad, otherGrads] = softmaxCostGrad(model, params, trainData)
  topHidVecs = trainData.topHidVecs;
  curBatchSize = params.curBatchSize;
  inputMask = trainData.inputMask;
  T = trainData.T;
  srcMaxLen = trainData.srcMaxLen;
  
  % init grads
  [softmaxGrad] = initSoftmaxGrad(params);
  if params.attnFunc>0 || params.posModel==3
    softmaxGrad.srcHidVecs = zeroMatrix([params.lstmSize, curBatchSize, params.numSrcHidVecs], params.isGPU, params.dataType);
  end
  otherGrads.ht = zeroMatrix(size(topHidVecs), params.isGPU, params.dataType);
  
  % init costs
  costs.total = zeroMatrix([1, 1], params.isGPU, params.dataType);
  costs.word = zeroMatrix([1, 1], params.isGPU, params.dataType);
  if params.posModel>0
    costs.pos = zeroMatrix([1, 1], params.isGPU, params.dataType);
  end
  
  if params.posModel==3
    wordCount = 0;
    otherGrads.allEmbGrads = zeroMatrix([params.lstmSize, trainData.numInputWords], params.isGPU, params.dataType);
    otherGrads.allEmbIndices = zeros(trainData.numInputWords, 1);
  end
  
  %% predict words from srcMaxLen to T
  for startT=srcMaxLen:params.softmaxStep:T
    endT = startT + params.softmaxStep -1;
    if endT>T
      endT = T;
    end
    numTimeSteps = (endT-startT+1);
    numExamples = numTimeSteps*curBatchSize;
  
    range = startT:endT;
    tgtRange = (startT-srcMaxLen+1):(endT-srcMaxLen+1);
    
    % h_t
    h_t = reshape(topHidVecs(:, :, range), params.lstmSize, numExamples);
    
    % positional model 3
    if params.posModel==3
      batchData.srcPosVecs = reshape(trainData.srcPosVecs(:, :, tgtRange), params.lstmSize, numExamples);
      batchData.posIds = [trainData.srcPosData(tgtRange).posIds];
      batchData.nullIds = [trainData.srcPosData(tgtRange).nullIds];
      batchData.eosIds = [trainData.srcPosData(tgtRange).eosIds];
      batchData.colIndices = [trainData.srcPosData(tgtRange).colIndices];
    else
      batchData = [];
    end
    
    % predicted words
    predWords = reshape(trainData.tgtOutput(:, tgtRange), 1, numExamples);
    
    % prepare mask
    curMask.mask = reshape(inputMask(:, range), 1, numExamples);
    curMask.unmaskedIds = find(curMask.mask);
    curMask.maskedIds = find(~curMask.mask);
    
    % predict
    if params.numClasses>0
      predClasses = mod(predWords, params.numClasses) + 1;
      predInClasses = floor((predWords-1)/params.numClasses + 1e-9) + 1;
      [word_cost, word_softmaxGrad, word_ht_grad , otherBatchGrads] = batchSoftmax('W_soft_class', h_t, predClasses, model, params, trainData, batchData, curMask, predInClasses);
    else
      [word_cost, word_softmaxGrad, word_ht_grad, otherBatchGrads] = batchSoftmax('W_soft', h_t, predWords, model, params, trainData, batchData, curMask);
    end
    costs.total = costs.total + word_cost;
    costs.word = costs.word + word_cost;
    
    %% grads
    if trainData.isTest==0
      fields = fieldnames(word_softmaxGrad);
      for ii=1:length(fields)
        field = fields{ii};
        softmaxGrad.(field) = softmaxGrad.(field) + word_softmaxGrad.(field);
      end
      
      % class-based softmax
      if params.numClasses>0 
        softmaxGrad.W_soft_inclass(:, :, otherBatchGrads.indices) = softmaxGrad.W_soft_inclass(:, :, otherBatchGrads.indices) + otherBatchGrads.W_soft_inclass;
      end
      
      % positional model 3
      if params.posModel==3
        % update embs of <p_n> and <p_eos>
        tmpIndices = [batchData.nullIds batchData.eosIds];
        numWords = length(tmpIndices);
        otherGrads.allEmbIndices(wordCount+1:wordCount+numWords) = [params.nullPosId*ones(1, length(batchData.nullIds)) params.eosPosId*ones(1, length(batchData.eosIds))];
        otherGrads.allEmbGrads(:, wordCount+1:wordCount+numWords) = otherBatchGrads.srcPosVecs(:, tmpIndices);
        wordCount = wordCount + numWords;
        
        if ~isempty(batchData.posIds)
          [linearIndices] = getTensorLinearIndices(trainData.srcHidVecs, batchData.posIds, batchData.colIndices);
          softmaxGrad.srcHidVecs(linearIndices) = softmaxGrad.srcHidVecs(linearIndices) + reshape(otherBatchGrads.srcPosVecs(:, batchData.posIds), 1, []);
        end
        
      end
            
      % grad_ht
      otherGrads.ht(:, :, range) = otherGrads.ht(:, :, range) + reshape(word_ht_grad, [params.lstmSize, curBatchSize, numTimeSteps]);
    end
  end
  
  if params.posModel==3
    otherGrads.allEmbGrads(:, wordCount+1:end) = [];
    otherGrads.allEmbIndices(wordCount+1:end) = [];
  end
  
  %% predict positions from (srcMaxLen-1) to (T-1)
  if params.posModel>0
    for startT=(srcMaxLen-1):params.softmaxStep:(T-1)
      endT = startT + params.softmaxStep -1;
      if endT>(T-1)
        endT = T-1;
      end
      numTimeSteps = (endT-startT+1);
      numExamples = numTimeSteps*curBatchSize;
      range = startT:endT;

      % predicted positions
      predPositions = reshape(trainData.srcPos(:, (startT-srcMaxLen+2):(endT-srcMaxLen+2)), 1, numExamples) - (params.startPosId-1);
    
      % h_t
      h_t = reshape(topHidVecs(:, :, range), params.lstmSize, numExamples);

      % prepare mask
      curMask.mask = reshape(inputMask(:, range), 1, numExamples);
      curMask.unmaskedIds = find(curMask.mask);
      curMask.maskedIds = find(~curMask.mask);

      [pos_cost, pos_softmaxGrad, pos_ht_grad] = batchSoftmax('W_softPos', h_t, predPositions, model, params, trainData, batchData, curMask);
      costs.total = costs.total + pos_cost;
      costs.pos = costs.pos + pos_cost;
      
      % grads
      if trainData.isTest==0
        fields = fieldnames(pos_softmaxGrad);
        for ii=1:length(fields)
          field = fields{ii};
          softmaxGrad.(field) = softmaxGrad.(field) + pos_softmaxGrad.(field);
        end
        
        % grad_ht
        otherGrads.ht(:, :, range) = otherGrads.ht(:, :, range) + reshape(pos_ht_grad, [params.lstmSize, curBatchSize, numTimeSteps]);
      end
    end
  end
end

function [cost, softmaxGrad, grad_ht, otherGrads] = batchSoftmax(matrixName, h_t, origPredLabels, model, params, trainData, batchData, curMask, varargin)
%%%
%
% Perform softmax prediction and backprop.
%   matrixName: 'W_soft' for predicting words (mostly used), and
%               'W_softPos' for predicting positions.
% When param.numClasses>0: perform class-based softmax. origPredLabels are class
%   labels. Predicting class labels is like predicting words in the regular
%   softmax. Besides, we need to predict the inclass word indices.
%
%%%
  mask = curMask.mask;
  unmaskedIds = curMask.unmaskedIds;
  maskedIds = curMask.maskedIds;
  
  %% h_t -> softmax_h
  if params.attnFunc>0 % attention mechanism
    [softmax_h, attnInput, attn_h_concat, alignWeights, alignScores] = lstm2softHid(h_t, params, model, trainData.srcHidVecs, curMask);
  elseif params.posModel==3 % positional model
    [softmax_h, interSoftInput] = lstm2softHid(h_t, params, model, batchData.srcPosVecs, curMask);
  else
    [softmax_h, interSoftInput] = lstm2softHid(h_t, params, model);
  end

  %% softmax_h -> predictions
  [probs, scores, norms] = softmax(model.(matrixName)*softmax_h, mask);
  % cost
  predLabels = origPredLabels(unmaskedIds);
  scoreIndices = sub2ind(size(scores), predLabels, unmaskedIds); % 1 * length(tgtPredictedWords)
  cost = - sum(scores(scoreIndices)) + sum(log(norms).*mask);
  
  % class-based softmax
  if params.numClasses > 0
    predInClass = varargin{1};
    predInClass = predInClass(unmaskedIds);
    
    % in class loss
    % model.W_soft_inclass(:,:,curClasses): classSize * softmaxSize * batchSize
    % softmax_h: softmaxSize * batchSize
    % inClassRaw: classSize * batchSize (sum across softmaxSize, dim 2)
    curClasses = origPredLabels;
    inClassRaw = reshape(sum(bsxfun(@times, model.W_soft_inclass(:,:,curClasses), permute(softmax_h, [3 1 2])), 2), params.classSize, params.curBatchSize);
    [inClassProbs, inClassScores, inClassNorms] = softmax(inClassRaw, mask);
    
    inClassScoreIndices = sub2ind(size(inClassScores), predInClass, unmaskedIds);
    inClassCost = - sum(inClassScores(inClassScoreIndices)) + sum(log(inClassNorms).*mask);
    
    cost = cost + inClassCost;
  end
  
  %% grad
  softmaxGrad = [];
  grad_ht = [];
  otherGrads = [];
  if trainData.isTest==0 % compute grad
    %% loss -> grad_softmax_h
    probs(scoreIndices) = probs(scoreIndices) - 1; % minus one at predicted words

    % softmax_h
    grad_softmax_h = model.(matrixName)'* probs;
    
    % class-based softmax
    if params.numClasses > 0 
      inClassProbs(inClassScoreIndices) = inClassProbs(inClassScoreIndices) - 1;

      % W_soft_inclass(:,:,curClasses): classSize * softmaxSize * batchSize
      % inClassProbs: classSize * batchSize
      % grad_softmax_h: softmaxSize * batchSize (sum across classSize, dim 1)
      grad_softmax_h = grad_softmax_h + squeeze(sum(bsxfun(@times, model.W_soft_inclass(:,:,curClasses), permute(inClassProbs, [1 3 2])), 1));
    end

    %% grad_softmax_h -> h_t
    if params.softmaxDim>0 || params.attnFunc>0 || params.posModel==3 % softmax compression or attention
      if params.softmaxDim>0 || params.posModel==3 % f(W_h * interSoftInput)
        % f'(softmax_h).*grad_softmax_h
        tmpResult = params.nonlinear_f_prime(softmax_h).*grad_softmax_h;

        % grad.W_h
        softmaxGrad.W_h = tmpResult*interSoftInput';

        if params.softmaxDim>0
          % grad_ht
          grad_ht = model.W_h'*tmpResult;
        else
          % grad_srcPosH: [srcPosVecs; h_t]
          grad_srcPosH = model.W_h'*tmpResult;
          
          % grad_ht
          grad_ht = grad_srcPosH(params.lstmSize+1:end, :);
          
          % grad srcPosVecs
          otherGrads.srcPosVecs = grad_srcPosH(1:params.lstmSize, :);
        end
      elseif params.attnFunc>0 % f(W_ah*[attn_t; tgt_h_t])
        [softmaxGrad, grad_ht] = attnBackprop(model, trainData.topHidVecs, softmax_h, grad_softmax_h, attn_h_concat, alignWeights, alignScores, attnInput, params);
      end
    else % normal softmax
      grad_ht = grad_softmax_h;
    end
    
    %% loss -> W_soft. 
    % Note: do not move this part up; otherwise, the case attnFunc>0 will
    % fail because softmaxGrad is only created after calling attnBackprop,
    % which means anything touches softmaxGrad before will be lost.
    softmaxGrad.(matrixName) = probs*softmax_h';
    
    if params.numClasses>0 % class-based softmax
      numWords = length(unmaskedIds);
      % inClassProbs(:, unmaskedIds): classSize * numWords
      % softmax_h(:, unmaskedIds): softmaxSize * numWords
      % W_soft_inclass: classSize * softmaxSize * numWords
      W_soft_inclass_grads = bsxfun(@times, permute(inClassProbs(:, unmaskedIds),[1 3 2]), permute(softmax_h(:, unmaskedIds),[3 1 2]));
      
      % grad.W_soft_inclass: (classSize * softmaxSize) * numWords
      W_soft_inclass_grads = reshape(W_soft_inclass_grads, [params.classSize*params.softmaxSize numWords]);
      
      % accumulate
      [otherGrads.W_soft_inclass, otherGrads.indices] = aggregateMatrix(W_soft_inclass_grads, curClasses(unmaskedIds), params.isGPU, params.dataType);
      otherGrads.W_soft_inclass = reshape(otherGrads.W_soft_inclass, [params.classSize params.softmaxSize length(otherGrads.indices)]);
    end
  end % end isTest
  
  
  % assert
  if params.assert
    if params.isGPU
      assert(gather(sum(sum(abs(scores(:, maskedIds)))))==0);
    else
      assert(sum(sum(abs(scores(:, maskedIds))))==0);
    end
    
    if params.numClasses > 0
      if params.isGPU
        assert(gather(sum(sum(abs(inClassScores(:, maskedIds)))))==0);
      else
        assert(sum(sum(abs(inClassScores(:, maskedIds))))==0);
      end
    end
  end
end

function [softmaxGrad] = initSoftmaxGrad(params)
  %% h_t -> softmax input
  if params.attnFunc>0 % attention mechanism
    softmaxGrad.W_a = zeroMatrix([params.numSrcHidVecs, params.lstmSize], params.isGPU, params.dataType);
    % attn_t = H_src * a_t
    % h_attn_t = f(W_ah * [attn_t; h_t])
    softmaxGrad.W_ah = zeroMatrix([params.attnSize, 2*params.lstmSize], params.isGPU, params.dataType);
  elseif params.softmaxDim>0 % compress softmax
    softmaxGrad.W_h = zeroMatrix([params.softmaxDim, params.lstmSize], params.isGPU, params.dataType);
  end
  
  if params.posModel==3
    % h_pos_t = f(W_h * [src_pos_t; h_t])
    softmaxGrad.W_h = zeroMatrix([params.posSoftSize, 2*params.lstmSize], params.isGPU, params.dataType);
  end
  
  % Note that softmaxSize has been set in initLSTM(), file trainLSTM.m
  % softmaxSize is either equal to attnSize, softmaxDim, or lstmSize
  
  %% softmax input -> predictions
  if params.numClasses == 0 % normal
    % W_soft
    softmaxGrad.W_soft = zeroMatrix([params.outVocabSize, params.softmaxSize], params.isGPU, params.dataType);
  else % class-based
    % W_soft_class: numClasses * softmaxSize
    softmaxGrad.W_soft_class = zeroMatrix([params.numClasses, params.softmaxSize], params.isGPU, params.dataType);
    
    % W_soft_inclass: classSize * softmaxSize * numClasses
    softmaxGrad.W_soft_inclass = zeroMatrix([params.classSize, params.softmaxSize, params.numClasses], params.isGPU, params.dataType);
  end
  
  % positional models
  if params.posModel>0
    softmaxGrad.W_softPos = zeroMatrix([params.posVocabSize, params.softmaxSize], params.isGPU, params.dataType);
  end
end