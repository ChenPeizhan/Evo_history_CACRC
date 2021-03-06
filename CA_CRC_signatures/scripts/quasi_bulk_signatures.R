require(gtools)
require(nnls)
require(SomaticSignatures)
require(RColorBrewer)
require(vioplot)

#########################################################################################################################
### User specified parameters; Update as applicable ###
setwd('/PROJECT_DATA_PATH/')
# Replace with paths to the relevant files in local #
hg19.path <- "/USER_PATH/ucsc.hg19.fasta"
hg38.path <- "/USER_PATH/ucsc.hg38.fasta"
tcga.coad.maf.path <- "/USER_PATH/TCGA.COAD.mutect.853e5584-b8c3-4836-9bda-6e7e84a64d97.DR-7.0.somatic.maf"
tcga.read.maf.path <- "/USER_PATH/TCGA.READ.mutect.c999f6ca-0b24-4131-bc53-1665948f8e3f.DR-7.0.somatic.maf"
cosmic.signatures.path <- "/USER_PATH/signatures_probabilities.txt"
### User specified parameters; Update as applicable ###
#########################################################################################################################
# Script metadata

msl <- read.table(file = 'data/master.sample.list.csv', sep = ',', header = T)
sets <- sort(unique(msl$sampleInfo[which(msl$retain == 1)]))

# false discovery rate
fdr.threshold <- 0.05

# calling criteria
variant.read.cutoff <- 2
vaf.cutoff <- 0.01
coverage.cutoff <- 10

# mutation filtering criteria
bases <- c('A', 'C', 'G', 'T')

# stability status assignment criteria
signature.threshold <- 0.5

# signature information
contexts <- paste(rep(c('CA', 'CG', 'CT', 'TA', 'TC', 'TG'), each = 16), 
                  rep(apply(permutations(n = 4, v=c('A', 'C', 'G', 'T'), r = 2, repeats.allowed = T), 1, function(x) paste(x, collapse = '.')), 6))
context.names <- sapply(as.character(contexts), function(x) paste(gsub('\\.', substr(x, 1, 1), strsplit(x, ' ')[[1]][2]), gsub('\\.', substr(x, 2, 2), strsplit(x, ' ')[[1]][2]), sep = '>'))
prc <- read.table(cosmic.signatures.path, sep = '\t', header = T, stringsAsFactors = F)
unordered.contexts <- paste(gsub('>', '', prc$Substitution.Type), paste(substr(prc$Trinucleotide, 1, 1), substr(prc$Trinucleotide, 3, 3), sep = '.'))
prc <- prc[order(unordered.contexts), ]
rownames(prc) <- contexts
prc.proven <- prc[, paste('Signature.', 1:30, sep = '')]
tnf <- read.table("data/trinucleotide.frequencies.tsv", header = T, stringsAsFactors = F)
tnf$genome.to.exome <- (tnf$exome / tnf$genome)
frequencies <- tnf$genome.to.exome[match(as.character(sapply(contexts, function(x) paste(substr(x,4,4), substr(x,1,1), substr(x,6,6), sep = ''))),
                                         tnf$type)]
prc.proven.exome <- prc.proven
for(i in ncol(prc.proven.exome)){
  prc.proven.exome[, i] <- prc.proven.exome[, i] * frequencies
  prc.proven.exome[, i] <- prc.proven.exome[, i] / sum(prc.proven.exome[, i])
}

# active signatures in CRC
active.signature.numbers <-  c(1, 2, 5, 6, 10, 13, 17)
active.signatures <- paste('Signature.', active.signature.numbers, sep = '')

# signature annotations
signature.annotations <- read.table(file = "data/signature.annotations.csv", 
                                    sep = ',', col.names = c('process', 'association', 'type', 'clock.like'))
signature.annotations$type <- sapply(1:nrow(signature.annotations), function(x) if(signature.annotations$association[x] == 'Unknown aetiology') 
{paste(signature.annotations$process[x], signature.annotations$association[x])} else {paste(signature.annotations$association[x])})

# signature colour mapping
qual_col_pals = brewer.pal.info[brewer.pal.info$category == 'qual',]
col_vector = unlist(mapply(brewer.pal, qual_col_pals$maxcolors, rownames(qual_col_pals)))
col_vector[c(9, 10, 15)] <- col_vector[26 + c(3, 4, 7)]
color.map <- data.frame(signature = colnames(prc.proven), 
                        col = col_vector[match(signature.annotations$type, unique(signature.annotations$type))])

#########################################################################################################################
## A) Read in and process CA-CRC and sporadic CRC mutation data

## read in CA-CRC mutation data, assign mutations to individual samples,
## and find flanking bases (trinucleotide context) for all mutations
for(set in sets){
  print(set)
  
  msl.sub <- msl[which((msl$sampleInfo == set) & (msl$retain == 1)), ]
  somatic.samples <- msl.sub$sampleID[which(msl.sub$type %in% c('proximal', 'polyp', 'cancer'))]
  
  set.name <- msl$setID[match(set, msl$sampleInfo)]
  df <- read.table(file = paste('data/', set.name, '.snv.total.annotated.txt', sep = ''),
                   sep = '\t',
                   header = T)
  
  # assign mutations to samples
  variant.reads <- as.data.frame(df[, match(paste(somatic.samples, '.NV', sep = ''), colnames(df))])
  vafs <- as.data.frame(df[, match(paste(somatic.samples, '.VAF', sep = ''), colnames(df))])
  coverage <- as.data.frame(df[, match(paste(somatic.samples, '.NR', sep = ''), colnames(df))])
  df$samples <- sapply(1:nrow(df), 
                       function(x) paste(somatic.samples[which((variant.reads[x,] > variant.read.cutoff) & (vafs[x,] > vaf.cutoff) & (coverage[x,] > coverage.cutoff))], collapse = ':'))
  
  # add mutation contexts
  vr <- VRanges(seqnames = Rle(paste(df$chr, sep = '')), 
                ranges = IRanges(start = df$start, end = df$end),
                ref = as.character(df$ref),
                alt = as.character(df$alt))
  file = hg19.path
  fa <- open(FaFile(file, sprintf("%s.fai", file)))
  vr.tmp <- mutationContext(vr = vr, ref = fa, k = 3)
  df$context <- paste(vr.tmp$alteration, vr.tmp$context)
  
  assign(paste('df.', set, sep = ''), df)
}

## read in COAD and READ TCGA mutation data and find flanking bases 
## (trinucleotide context) for all mutations
df.coad <- read.table(file = tcga.coad.maf.path, 
                 sep = '\t',
                 quote = '',
                 header = T,
                 stringsAsFactors = F)
df.coad$disease <- 'COAD'
df.read <- read.table(file = tcga.read.maf.path, 
                      sep = '\t',
                      quote = '',
                      header = T,
                      stringsAsFactors = F)
df.read$disease <- 'READ'
df <- rbind(df.coad, df.read)

# filter combined data frame
df <- df[which(df$FILTER == 'PASS'),]
df <- df[which(df$Reference_Allele %in% bases),]
df <- df[which(df$Tumor_Seq_Allele2 %in% bases),]

# add sample names
df$set <- sapply(1:nrow(df), function(x) paste(strsplit(df$Tumor_Sample_Barcode[x], '-')[[1]][1:3], collapse = '-'))
sets.crc <- unique(df$set)

# add mutation contexts
vr <- VRanges(seqnames = Rle(paste(df$Chromosome, sep = '')), 
              ranges = IRanges(start = df$Start_Position, end = df$End_Position),
              ref = as.character(df$Reference_Allele),
              alt = as.character(df$Tumor_Seq_Allele2))
file = hg38.path
fa <- open(FaFile(file, sprintf("%s.fai", file)))
vr.tmp <- mutationContext(vr = vr, ref = fa, k = 3)
df$context <- paste(vr.tmp$alteration, vr.tmp$context)
assign('df.crc', df)

#########################################################################################################################
## B) Find quasi-bulk signatures in CA-CRC and bulk signatures in CRC

## Assign quasi-bulk cancer signatures to CA-CRC samples using non-negative least squares regression
sample.contexts <- data.frame(row.names = contexts)
# Count the mutations of each type (based on 96 type classification) in each sample
for(set in sets){
  print(set)
  df <- get(paste('df.', set, sep = ''))
  
  msl.sub <- msl[which((msl$sampleInfo == set) & (msl$retain == 1)), ]
  cancer.samples <- msl.sub$sampleID[which(msl.sub$type == 'cancer')]
  
  ids <- unique(unlist(lapply(cancer.samples, function(x) grep(x, df$samples))))
  df.sub <- df[ids, ]
  
  counts <- as.numeric(table(factor(df.sub$context, levels = contexts)))
  sample.contexts <- cbind(sample.contexts, counts)
  colnames(sample.contexts)[ncol(sample.contexts)] <- set 
}
signatures <- prc.proven.exome[, match(active.signatures, colnames(prc.proven.exome))]
sample.signatures <- as.data.frame(lapply(1:ncol(sample.contexts), function(y) nnls(as.matrix(signatures), sample.contexts[,y])$x))
fitted.signatures <- as.data.frame(lapply(1:ncol(sample.contexts), function(y) nnls(as.matrix(signatures), sample.contexts[,y])$fitted))
r.squared <- sapply(1:ncol(sample.contexts), function(y) 1 - (nnls(as.matrix(signatures), sample.contexts[,y])$deviance / sum(sample.contexts[,y]^2)))
r.squared.cacrc <- data.frame(set = colnames(sample.contexts), r.squared = r.squared)
sample.residual.contexts <- as.data.frame(lapply(1:ncol(sample.contexts), function(y) nnls(as.matrix(signatures), sample.contexts[,y])$residuals))
rownames(sample.signatures) <- active.signatures
colnames(sample.signatures) <- colnames(sample.contexts)
colnames(sample.residual.contexts) <- colnames(sample.contexts)
sample.signatures.cacrc <- sample.signatures
normalised.signatures.cacrc <- apply(sample.signatures.cacrc, 2, function(x) x / sum(x))
sample.contexts.cacrc <- sample.contexts

# 96 channel plots
sample.contexts <- sample.contexts.cacrc
for(set in sets){
  print(set)
  
  pdf(file = paste('quasi_bulk_plots/', set, '.signature.pdf', sep = ''),
      width = 11.69, height = 8.27)
  par(mfrow = c(2, 1))
  barplot(sample.contexts[, match(set, colnames(sample.residual.contexts))],
          col = rep(c('blue', 'black', 'red', 'grey', 'green', 'pink'), each = 16),
          main = paste(set, 'Signature'), names.arg = context.names, las = 2, cex.names = 0.5)
  barplot(fitted.signatures[, match(set, colnames(sample.residual.contexts))],
          col = rep(c('blue', 'black', 'red', 'grey', 'green', 'pink'), each = 16),
          main = paste(set, 'Fitted'), names.arg = context.names, las = 2, cex.names = 0.5)
  text(x = 10, y = max(fitted.signatures[, match(set, colnames(sample.residual.contexts))]) * 0.8,
       labels = paste('R-squared =', round(r.squared.cacrc$r.squared[match(set, r.squared.cacrc$set)], 2)))
  dev.off()
}

# composite signature
pdf(file = paste('quasi_bulk_plots/Aggregate.signature.pdf', sep = ''),
    width = 11.69, height = 8.27 / 2)
barplot(rowSums(sample.contexts),
        col = rep(c('blue', 'black', 'red', 'grey', 'green', 'pink'), each = 16), 
        main = 'All mutations', names.arg = context.names, las = 2, cex.names = 0.5)
dev.off()

# bar plot signature coefficients all samples
sample.signatures <- sample.signatures.cacrc
sample.signatures <- sample.signatures[, order(colnames(sample.signatures))]
pdf(file = 'quasi_bulk_plots/Modeled.signatures.pdf')
par(mar = c(8, 4, 4, 4))
barplot(as.matrix(sample.signatures), 
        col = as.character(color.map$col[match(rownames(sample.signatures), color.map$signature)]),
        las = 2,
        ylab = 'Mutations', main = 'Signatures',
        ylim = c(0, max(sample.signatures) * 2.2), yaxt = 'n')
axis(side = 2, at = seq(0, 1800, 100))
title(xlab = 'Samples', line = 6)
legend('topright', 
       legend = paste(rownames(sample.signatures), signature.annotations$association[match(rownames(sample.signatures), signature.annotations$process)]), 
       col = as.character(color.map$col[match(rownames(sample.signatures), color.map$signature)]),
       pch = 15)
dev.off()

# Assign signatures for sporadic CRCs
sample.contexts <- table(factor(df.crc$context, levels = contexts), factor(df.crc$set, levels = sets.crc))
signatures <- prc.proven.exome[, match(active.signatures, colnames(prc.proven.exome))]
sample.signatures <- as.data.frame(lapply(1:ncol(sample.contexts), function(y) nnls(as.matrix(signatures), sample.contexts[,y])$x))
r.squared <- sapply(1:ncol(sample.contexts), function(y) 1 - (nnls(as.matrix(signatures), sample.contexts[,y])$deviance / sum(sample.contexts[,y]^2)))
r.squared.crc <- data.frame(set = colnames(sample.contexts), r.squared = r.squared)
rownames(sample.signatures) <- active.signatures
colnames(sample.signatures) <- colnames(sample.contexts)
sample.signatures.crc <- sample.signatures
normalised.signatures.crc <- apply(sample.signatures.crc, 2, function(x) x / sum(x))
sample.contexts.crc <- sample.contexts

#########################################################################################################################
## C) Assess differences between CA-CRC and sporadic CRC

# Group CA-CRC and CRC samples into 'msi', 'pole' and 'stable' groups
cacrc.metadata <- data.frame(set = sets)
cacrc.msi <- colnames(normalised.signatures.cacrc)[which(normalised.signatures.cacrc[match('Signature.6', rownames(normalised.signatures.cacrc)),] > signature.threshold)]
cacrc.pole <- colnames(normalised.signatures.cacrc)[which(normalised.signatures.cacrc[match('Signature.10', rownames(normalised.signatures.cacrc)),] > signature.threshold)]
cacrc.metadata$msi <- sapply(1:nrow(cacrc.metadata), function(x) if(cacrc.metadata$set[x] %in% cacrc.msi) {T} else {F})
cacrc.metadata$pole <- sapply(1:nrow(cacrc.metadata), function(x) if(cacrc.metadata$set[x] %in% cacrc.pole) {T} else {F})
cacrc.metadata$stable <- !(cacrc.metadata$msi | cacrc.metadata$pole)
cacrc.metadata$group <- sapply(1:nrow(cacrc.metadata), function(x) c('msi', 'pole', 'stable')[which(as.logical(cacrc.metadata[x ,c('msi', 'pole', 'stable')]))])

crc.metadata <- data.frame(set = unique(df.crc$set))
crc.msi <- colnames(normalised.signatures.crc)[which(normalised.signatures.crc[match('Signature.6', rownames(normalised.signatures.crc)),] > signature.threshold)]
crc.pole <- colnames(normalised.signatures.crc)[which(normalised.signatures.crc[match('Signature.10', rownames(normalised.signatures.crc)),] > signature.threshold)]
crc.metadata$msi <- sapply(1:nrow(crc.metadata), function(x) if(crc.metadata$set[x] %in% crc.msi) {T} else {F})
crc.metadata$pole <- sapply(1:nrow(crc.metadata), function(x) if(crc.metadata$set[x] %in% crc.pole) {T} else {F})
crc.metadata$stable <- !(crc.metadata$msi | crc.metadata$pole)
crc.metadata$group <- sapply(1:nrow(crc.metadata), function(x) c('msi', 'pole', 'stable')[which(as.logical(crc.metadata[x ,c('msi', 'pole', 'stable')]))])

## Signatures in CA-CRC in comparison to sporadic

# Test for differences between CA-CRC and sporadic signatures
abs.tests <- expand.grid(signature = active.signatures, group = c('stable', 'msi'), comparison = 'absolute')
abs.tests$p.value <- sapply(1:nrow(abs.tests), function(x) wilcox.test(as.numeric(sample.signatures.crc[match(abs.tests$signature[x], rownames(sample.signatures.crc)), 
                                                                                                        match(crc.metadata$set[which(crc.metadata[[as.character(abs.tests$group[x])]])],colnames(sample.signatures.crc))]),
                                                                       as.numeric(sample.signatures.cacrc[match(abs.tests$signature[x], rownames(sample.signatures.cacrc)), 
                                                                                                          match(cacrc.metadata$set[which(cacrc.metadata[[as.character(abs.tests$group[x])]])],colnames(sample.signatures.cacrc))]))$p.value)

rel.tests <- expand.grid(signature = active.signatures, group = c('stable', 'msi'), comparison = 'relative')
rel.tests$p.value <- sapply(1:nrow(rel.tests), function(x) wilcox.test(as.numeric(normalised.signatures.crc[match(rel.tests$signature[x], rownames(normalised.signatures.crc)), 
                                                                                                            match(crc.metadata$set[which(crc.metadata[[as.character(rel.tests$group[x])]])],colnames(normalised.signatures.crc))]),
                                                                       as.numeric(normalised.signatures.cacrc[match(rel.tests$signature[x], rownames(normalised.signatures.cacrc)), 
                                                                                                              match(cacrc.metadata$set[which(cacrc.metadata[[as.character(rel.tests$group[x])]])],colnames(normalised.signatures.cacrc))]))$p.value)

tests <- rbind(abs.tests, rel.tests)
tests <- tests[order(tests$p.value),]
tests$stat <- sapply(1:nrow(tests), function(x) (tests$p.value[x] * nrow(tests)) / length(which(tests$p.value <= tests$p.value[x])))
tests$q.value <- sapply(1:nrow(tests), function(x) min(tests$stat[x:nrow(tests)]))
cacrc.vs.sporadic <- tests


# violin plot comparison of absolute signatures
tests <- cacrc.vs.sporadic
pdf(file = 'quasi_bulk_plots/comparison.to.sporadic.absolute.signatures.pdf',
    width = 11.69, height = 8.27)
par(mfrow = c(2, 4), oma = c(4,4,4,4))
for(sig in active.signatures){
  p.val.stable <- tests$p.value[which((tests$comparison == 'absolute') & (tests$signature == sig) & (tests$group == 'stable'))]
  p.val.msi <- tests$p.value[which((tests$comparison == 'absolute') & (tests$signature == sig) & (tests$group == 'msi'))]
  
  crc.vals.stable <- as.numeric(sample.signatures.crc[match(sig, rownames(sample.signatures.crc)), match(crc.metadata$set[which(crc.metadata$stable)], colnames(sample.signatures.crc))]) 
  crc.vals.msi <- as.numeric(sample.signatures.crc[match(sig, rownames(sample.signatures.crc)), match(crc.metadata$set[which(crc.metadata$msi)], colnames(sample.signatures.crc))]) 
  cacrc.vals.stable <- as.numeric(sample.signatures.cacrc[match(sig, rownames(sample.signatures.cacrc)), match(cacrc.metadata$set[which(cacrc.metadata$stable)], colnames(sample.signatures.cacrc))]) 
  cacrc.vals.msi <- as.numeric(sample.signatures.cacrc[match(sig, rownames(sample.signatures.cacrc)), match(cacrc.metadata$set[which(cacrc.metadata$msi)], colnames(sample.signatures.cacrc))]) 
  y.max <- max(c(crc.vals.stable, crc.vals.msi, cacrc.vals.stable, cacrc.vals.msi))
  vioplot(crc.vals.stable,
          cacrc.vals.stable,
          crc.vals.msi,
          cacrc.vals.msi,
          ylim = c(0, y.max * 1.2),
          col = as.character(color.map$col[match(sig, color.map$signature)]),
          names = c(rep(c('Sp.', 'CA'), 2)))
  text(x = c(1.5, 3.5), y = rep(y.max * 1.15, 2), labels = paste('P=', round(c(p.val.stable, p.val.msi), 2), sep = ''))
  lines(x = c(1, 2), y = rep(y.max * 1.1, 2))
  lines(x = c(3, 4), y = rep(y.max * 1.1, 2))
  title(ylab = 'Signature Exposure', main = gsub('\\.', ' ', sig))
  axis(side = 1, at = c(1.5, 3.5), labels = c('MSS', 'MSI'), line = 2)
}
dev.off()

# violin plot comparison of relative signatures
tests <- cacrc.vs.sporadic
pdf(file = 'quasi_bulk_plots/comparison.to.sporadic.relative.signatures.pdf',
    width = 11.69, height = 8.27)
par(mfrow = c(2, 4), oma = c(4,4,4,4))
for(sig in active.signatures){
  p.val.stable <- tests$p.value[which((tests$comparison == 'relative') & (tests$signature == sig) & (tests$group == 'stable'))]
  p.val.msi <- tests$p.value[which((tests$comparison == 'relative') & (tests$signature == sig) & (tests$group == 'msi'))]
  
  crc.vals.stable <- as.numeric(normalised.signatures.crc[match(sig, rownames(normalised.signatures.crc)), match(crc.metadata$set[which(crc.metadata$stable)], colnames(normalised.signatures.crc))]) 
  crc.vals.msi <- as.numeric(normalised.signatures.crc[match(sig, rownames(normalised.signatures.crc)), match(crc.metadata$set[which(crc.metadata$msi)], colnames(normalised.signatures.crc))]) 
  cacrc.vals.stable <- as.numeric(normalised.signatures.cacrc[match(sig, rownames(normalised.signatures.cacrc)), match(cacrc.metadata$set[which(cacrc.metadata$stable)], colnames(normalised.signatures.cacrc))]) 
  cacrc.vals.msi <- as.numeric(normalised.signatures.cacrc[match(sig, rownames(normalised.signatures.cacrc)), match(cacrc.metadata$set[which(cacrc.metadata$msi)], colnames(normalised.signatures.cacrc))]) 
  y.max <- max(c(crc.vals.stable, crc.vals.msi, cacrc.vals.stable, cacrc.vals.msi))
  vioplot(crc.vals.stable,
          cacrc.vals.stable,
          crc.vals.msi,
          cacrc.vals.msi,
          ylim = c(0, y.max * 1.2),
          col = as.character(color.map$col[match(sig, color.map$signature)]),
          names = c(rep(c('Sp.', 'CA'), 2)))
  text(x = c(1.5, 3.5), y = rep(y.max * 1.15, 2), labels = paste('P=', round(c(p.val.stable, p.val.msi), 2), sep = ''))
  lines(x = c(1, 2), y = rep(y.max * 1.1, 2))
  lines(x = c(3, 4), y = rep(y.max * 1.1, 2))
  title(ylab = 'Relative Signature Exposure', main = gsub('\\.', ' ', sig))
  axis(side = 1, at = c(1.5, 3.5), labels = c('MSS', 'MSI'), line = 2)
}
dev.off()

