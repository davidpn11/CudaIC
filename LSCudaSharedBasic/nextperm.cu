#include <stddef.h>
#include <stdio.h>
#include "LIS.cu"
#include "LDS.cu"
#include <time.h>

#define NUM_THREADS 8192
#define THREAD_PER_BLOCK 1024
#define LENGTH 10
/*
#define NUM_SM 8
#define MAX_THREAD_PER_SM 2048
#define LENGTH 10
#define MAX_SHARED_PER_BLOCK 49152
#define SHARED_PER_THREAD 	(LENGTH*LENGTH+LENGTH)
#define THREAD_PER_BLOCK 	MAX_SHARED_PER_BLOCK/SHARED_PER_THREAD
#define NUM_BLOCKS 			(THREAD_PER_SM*NUM_SM)/THREAD_PER_BLOCK
#define NUM_THREADS 		NUM_BLOCKS*THREAD_PER_BLOCK
*/


void inversion(int* dest, int* in, int length){
	int i;
	for(i = 0; i < length; i++){
		dest[i] = in[length-i-1];
	}
}

void rotation(int* dest, int* in, int length){
  int i;	
  dest[0] = in[length-1];
  for (i = 1; i < length; i++)
     dest[i] = in[i-1];

}

int next_permutation(int *array, size_t length) {
	size_t i, j;
	int temp;
	// Find non-increasing suffix
	if (length == 0)
		return 0;
	i = length - 1;
	while (i > 0 && array[i - 1] >= array[i])
		i--;
	if (i == 0)
		return 0;
	
	// Find successor to pivot
	j = length - 1;
	while (array[j] <= array[i - 1])
		j--;
	temp = array[i - 1];
	array[i - 1] = array[j];
	array[j] = temp;
	
	// Reverse suffix
	j = length - 1;
	while (i < j) {
		temp = array[i];
		array[i] = array[j];
		array[j] = temp;
		i++;
		j--;
	}
	return 1;
}

void printVector(int* array, int length){
	int k;
	for(k = 0; k < 4; k++){
		//printf("%d - ",array[k]);	
	}
	//printf("\n");
}

int fatorial(int n){
	int i;
	int result = 1;
	for(i = n; i > 1; i--){
		result *= i;
	}
	return result;
}

void criaSequencias(int* dest, int* in,int length, unsigned int* numSeqReady){
	//Inserir o pivor em primeiro lugar, e sua inversão
	memcpy(dest,in, sizeof(int)*length);
	inversion(dest+length, dest, length);
	*numSeqReady += 2;

	//Rotaciona o pivor, e inverte os elementos produzidos
	int i;
	for(i = 0; i < (length-1); i++, *numSeqReady+=2){
		rotation(dest + (*numSeqReady)*length,dest + (*numSeqReady-2)*length, length); //Diminuição de dois elementos, para pular a inversão do pivor
		inversion(dest + (*numSeqReady+1)*length,dest+(*numSeqReady)*length, length);		
	}
}

//Min(|LIS(s)|, |LDS(s)|)
__global__
void decideLS(int *vector, unsigned int* lmin, int length, int numThread){
	extern __shared__ int s_vet[];
	int index = threadIdx.x + blockIdx.x*blockDim.x;

	if(index < numThread){
		int i;
		for(i = 0; i < length; i++){
			s_vet[i] = vector[index*length+i];
		}
		__syncthreads();

		unsigned int lLIS, lLDS; 
	
		lLIS = LIS(s_vet, length);
		lLDS = LDS(s_vet, length);

		lmin[index] = lLIS;

		if(lLDS < lmin[index]){
			lmin[index] = lLDS;	
		}
	}
	
}

int reduceLMinR(unsigned int* lMin_s, int tam){
	int i;
	unsigned int lMin_R = 0xFF;
	for(i = 0; i < tam; i++){
		if(lMin_R > lMin_s[i]){
			lMin_R = lMin_s[i];	
		}
	}
	return lMin_R;
}

void calcLMaxS(unsigned int* lMax_S, unsigned int* lMin_s, int tamVec, int tamGroup){
	int i;
	unsigned int lMin_R;
	//Número de conjuntos
	for(i = 0; i < tamVec/tamGroup; i++){
		lMin_R = reduceLMinR(lMin_s+i*tamGroup, tamGroup);
		if(*lMax_S < lMin_R){
			*lMax_S = lMin_R;
		}
	}

}
//Seja S o conjunto de todas las sequencias dos n primeiros números naturais.
//Defina R(s), com s \in S o conjunto de todas as sequencias que podem
//ser geradas rotacionando S.
//Defina LIS(s) e LDS(s) como você sabe e sejam |LIS(s)| e |LDS(s)| suas
//cardinalidades.
//Determinar Max_{s \in S}(Min_{s' \in R(s)}(Min(|LIS(s)|, |LDS(s)|)))


int main(){
	int* h_sequence;            //Vetor com a sequência pivor do grupo
	int* h_threadSequences;      //Vetor com as sequências criadas
	int* d_threadSequences;	    //Sequências produzidas para enviar para o device
	unsigned int* d_lMin_s;      //Vetor com os resultados de cada thread. L Mínimos do conjunto de R
	unsigned int* h_lMin_s;      

	clock_t start,end;

	//Aloca memória dos vetores	
	h_sequence = (int*) malloc(sizeof(int)*LENGTH);
	h_threadSequences = (int*) malloc(sizeof(int)*LENGTH*NUM_THREADS);
	h_lMin_s = (unsigned int*) malloc(sizeof(unsigned int)*NUM_THREADS);
	cudaMalloc(&d_threadSequences, sizeof(int)*LENGTH*NUM_THREADS);
	cudaMalloc(&d_lMin_s, sizeof(int)*NUM_THREADS);

	//Gera a sequencia primária, de menor ordem léxica	
	int i;
	for(i = 0; i < LENGTH; i++)
		h_sequence[i] = i+1;

	unsigned int numSeqReady = 0; //Número de sequêcias prontas
	unsigned int numSeqReadyAnt = 0;

	start = clock();
	unsigned int lMax_S = 0;

	//Length -1 porque devido a rotação pode sempre deixar o primeiro número fixo, e alternar os seguintes
	//Dividido por 2, porque a inversão cobre metade do conjunto.
	int counter = fatorial(LENGTH-1)/2;
        
    //Número de elementos em cada conjunto. Length (rotação) * 2 (inversão)    
	int tamGroup = 2*LENGTH;

	//Cada loop gera um conjunto de sequências. Elementos de S. Cada elemento possui um conjunto de R sequencias.
	while(counter){
		
		//Gera todo o conjunto R
		criaSequencias(h_threadSequences + numSeqReady*LENGTH, //Vetor com as sequências geradas
		    		   h_sequence, //Vetor pivor
                       LENGTH,
			           &numSeqReady); //Número de threads prontos

		if(numSeqReadyAnt != 0){
			cudaThreadSynchronize();
			//Envia os resultados obtidos para o host
			cudaMemcpy(h_lMin_s, d_lMin_s, sizeof(unsigned int)*numSeqReady, cudaMemcpyDeviceToHost);

			cudaThreadSynchronize();	
			calcLMaxS(&lMax_S, h_lMin_s, numSeqReadyAnt, tamGroup);
		}
		
		//Caso não tenha como inserir mais un conjunto inteiro no número de threads, então executa:
		if((numSeqReady+tamGroup) < NUM_THREADS){

			cudaMemcpy(d_threadSequences, h_threadSequences, sizeof(int)*numSeqReady*LENGTH, cudaMemcpyHostToDevice);
			cudaThreadSynchronize();
			//Cada thread calcula o LIS e o LDS de cada sequência
			decideLS<<<numSeqReady%THREAD_PER_BLOCK, ceil(((float) numSeqReady)/(float) THREAD_PER_BLOCK), sizeof(int)*LENGTH>>>
					   (d_threadSequences, d_lMin_s, LENGTH, numSeqReady);

			
			numSeqReadyAnt = numSeqReady;
			numSeqReady = 0; 
		}	

		//Cria a próxima sequência na ordem lexicográfica
		next_permutation(h_sequence+1,LENGTH-1);
		counter--;
	}
	end = clock();

	printf("Tempo: %f s\n", (float)(end-start)/CLOCKS_PER_SEC);

	printf("Lmax R = %d\n",lMax_S);

	free(h_sequence);
	free(h_threadSequences);
	free(h_lMin_s);
	cudaFree(d_threadSequences);
	cudaFree(d_lMin_s);
}
