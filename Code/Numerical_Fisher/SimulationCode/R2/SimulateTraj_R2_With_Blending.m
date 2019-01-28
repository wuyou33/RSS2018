% clear all; close all; clc;

%% SPAWN GOAL CONFIGURATION AND ROBOT POSITION. RANDOMLY IN THE WORKSPACE. 

%Define workspace limits. All in metres. 
xrange = [-0.5, 0.5];
yrange = [-0.5, 0.5];

%global variables.
global cm num_modes ng nd xg xr sig delta_t conf_thresh conf_max alpha_max sparsity_factor amp_sparsity_factor kappa projection_time;

%workspace parameters
max_ng = 6;
ng = datasample(3:max_ng, 1); %spawn random number of goals. Maximum number is 6. At least 2
nd = 2; %num of dimensions. by definition R^2
cm = {1,2}; %only control mode settings. 
num_modes = length(cm); %or 1 depending on whether the modes are [x, y] or [{x,y}]
init_mode_index = datasample(1:num_modes, 1);


%spawn random goals and random robot positions
xg = [rand(1,ng)*range(xrange) + xrange(1); rand(1,ng)*range(yrange) + yrange(1)]; %random goal positions. These will be treated as fixed parameters.
xr = [rand(1,1)*range(xrange) + xrange(1); rand(1,1)*range(yrange) + yrange(1)];
xr_true = xr; %store away random  robot position in a variable for reuse.

%human parameters
sparsity_factor = rand/4; %how often would the human control command be zero.
amp_sparsity_factor = rand/8; % how often the amplitude wiull be less that maximum. 
kappa = 20.0; % concentration paarameter for vonMisesFisher distribution
fprintf('The sparsity and amp factor are %f, %f\n', sparsity_factor, amp_sparsity_factor);

%disambiguation related params %UNUSED
sig = 0.01; %For Fisher information

%% Projection paramaters
projection_time = 4;
delta_t = 0.1; %For compute projections. 

%% simulation params
mode_comp_timesteps = 10; %time step gap between optimal mode computation. delta_t*mode_comp_timesteps is the time in seconds
exit_threshold = 0.02;
total_time_steps = 120; %with delta_t of 0.1, this amounts to 10 seconds. We will assume that "mode switches" don't take time. 

%%

%arbitrartion function parameters - Fixed parameters for shared control. 
conf_thresh = (1.05/ng);
conf_max = (1.1/ng);
alpha_max = 0.7;

%% PLOT GOALS AND CURRENT ROBOT POSITION. 
% 
% figure;
% scatter(xg(1,1:ng), xg(2,1:ng), 180, 'k', 'filled'); grid on; hold on;
% scatter(xr(1), xr(2), 140, 'r', 'filled');
% offset = [-0.1, 0.1];
% line(xrange+offset, [0,0], 'Color', 'r'); %draw x and y axes.
% line([0,0], yrange+offset, 'Color', 'g');
% axis([xrange + offset, yrange + offset]);
% axis square;


%% generate random user goal index. change color to magenta. 
random_goal_index = randsample(ng, 1); 
random_goal = xg(:, random_goal_index);
%%
% scatter(random_goal(1), random_goal(2), 180, 'm', 'filled'); grid on; hold on;

%% SAMPLE AN INTENT INFERENCE MECHANISM FOR THE CURRENT SIMULATION
intent_types = {'dft', 'conf', 'bayes'};
intent_type = intent_types{datasample(1:length(intent_types), 1)}; % or conf or bayes
% intent_type = 'dft';

%% %% USING MAX POTENTIAL AS BASE LINE
%variables to hold simulation data for MAX POTENTIAL
pgs_POT = zeros(ng, total_time_steps); %goal probabilities
optimal_modes_POT = zeros(total_time_steps-1, 1); %optimal modes. 
alpha_POT = zeros(total_time_steps-1, 1); %alpha values
uh_POT = zeros(nd, total_time_steps-1);
ur_POT = zeros(nd, total_time_steps-1);
blend_vel_POT = zeros(nd, total_time_steps-1);
curr_goal_POT = zeros(total_time_steps-1, 1); %current goal inference
traj_POT = zeros(nd, total_time_steps); %trajectory
traj_POT(:, 1) = xr; %initialize first data point of trajetcory
pgs_POT(:, 1) = (1/ng)*ones(ng, 1);%uniform probability to start off with. This is the true pg distribution during the course of the trajectory

current_optimal_mode_POT_index = init_mode_index;
current_optimal_mode_POT = cm{current_optimal_mode_POT_index};

hist_length = 15; %for Bayes filter. not used. 

for i=1:total_time_steps-1
    %compute the optimal mode. store it away. 
    if norm(traj_POT(:, i) - random_goal)/norm(traj_POT(:, 1)- random_goal) < exit_threshold
        fprintf('Within 10 percent of the original separation from goal. Stopping simulation\n');
        break;
    end
    curr_goal_index_POT = datasample(find(pgs_POT(:, i) == max(pgs_POT(:, i))), 1);
    curr_goal_POT(i) = curr_goal_index_POT;
    if mod(i-1, mode_comp_timesteps) == 0
        current_optimal_mode_POT_index = compute_optimal_mode_POT_R2(xg(:, curr_goal_index_POT), xr_true); 
        if length(current_optimal_mode_POT_index) > 1 %when there are equivalent modes. 
            current_optimal_mode_POT = cm{current_optimal_mode_POT_index(1)}; %pick the first one. 
            current_optimal_mode_POT_index = current_optimal_mode_POT_index(1); %update the index. 
        else
            if current_optimal_mode_POT_index ~= -1 %if -1, don't change any mode. keep previous node. So no need to update
                current_optimal_mode_POT = cm{current_optimal_mode_POT_index}; 
            end
        end
    end
    %gotta determine uh. Assumes human is executes the "straightest
    %possible motion in the current mode towards the specified goal". 
    uh = generate_full_uh(random_goal, xr); %noisy uh. Change gaussian sigma in the generate_full_uh accordingly. 
    zero_dim = setdiff(1:nd,current_optimal_mode_POT); %zero out the nonavailable control modes. 
    for jj=1:length(zero_dim)
        uh(zero_dim(jj)) = 0;
    end
    %normalize
    if norm(uh) > 0.2
        uh = 0.2*(uh./(norm(uh) + realmin));
    end
    if rand < amp_sparsity_factor
        uh = rand*uh;
    end
    %human and robot control commands and belnding
    ur = generate_autonomy(curr_goal_index_POT); %pfield autonomy command in full 2D space towards what it thinks is the current goal
    alpha_POT(i) = alpha_from_confidence(pgs_POT(curr_goal_index_POT, i)); %linear belnding param
    blend_vel = (1-alpha_POT(i))*uh + alpha_POT(i)*ur; %blended vel
    uh_POT(:, i) = uh; ur_POT(:, i) = ur; blend_vel_POT(:, i) = blend_vel;
    if strcmp(intent_type, 'dft')
        pgs_POT(:, i+1) = compute_p_of_g_dft_R2(uh, xr, pgs_POT(:, i));
    elseif strcmp(intent_type, 'bayes')
        pgs_POT(:, i+1) = compute_bayes_R2(uh, xr, pgs_POT(:, i));
%         pgs_POT(:, i+1) = compute_bayes_n_R2(uh_POT(:, max(1, i-hist_length+1):i), xr, pgs_POT(:,i));
    elseif strcmp(intent_type, 'conf')
        pgs_POT(:, i+1) = compute_conf_R2(uh, xr);
    end
    xr = sim_kinematics_R2(xr, blend_vel); %forward simulate kinematics with blending. 
    traj_POT(:, i+1) = xr;
    optimal_modes_POT(i) = current_optimal_mode_POT_index;
end

%% USING ENTROPY simulate motion towards random goal from starting xr

fprintf("SIMULATION USING ENTROPY INFORMATION \n");

xr = xr_true; %reset the robot position to starting position
pgs_ENT = zeros(ng, total_time_steps);
optimal_modes_ENT = zeros(total_time_steps-1, 1);
alpha_ENT = zeros(total_time_steps-1, 1);
uh_ENT = zeros(nd, total_time_steps-1);
ur_ENT = zeros(nd, total_time_steps-1);
blend_vel_ENT = zeros(nd, total_time_steps-1);
curr_goal_ENT = zeros(total_time_steps-1, 1);
traj_ENT = zeros(nd, total_time_steps);
traj_ENT(:, 1) = xr;
pgs_ENT(:, 1) = (1/ng)*ones(ng, 1);%uniform probability to start off with. This is the true pg distribution during the course of the trajectory
%internally projection
current_optimal_mode_ENT_index = init_mode_index;
current_optimal_mode_ENT = cm{current_optimal_mode_ENT_index};

for i=1:total_time_steps-1
    if norm(traj_ENT(:, i) - random_goal)/norm(traj_ENT(:, 1)- random_goal) < exit_threshold
        fprintf('Within 10 percent of the original separation from goal. Stopping simulation\n');
        break;
    end
    %compute the optimal mode. store it away. 
    curr_goal_index_ENT = datasample(find(pgs_ENT(:, i) == max(pgs_ENT(:, i))), 1);
    curr_goal_ENT(i) = curr_goal_index_ENT;
    if mod(i-1, mode_comp_timesteps) == 0
        current_optimal_mode_ENT_index = compute_optimal_mode_ENT_R2_human_model(intent_type, xr, pgs_ENT(:, i)); 
        if length(current_optimal_mode_ENT_index) > 1 %when there are equivalent modes. 
            current_optimal_mode_ENT = cm{current_optimal_mode_ENT_index(1)}; %pick the first one. 
            current_optimal_mode_ENT_index = current_optimal_mode_ENT_index(1); %update the index. 
        else
            if current_optimal_mode_ENT_index ~= -1 %if -1, don't change any mode. keep previous node. So no need to update
                current_optimal_mode_ENT = cm{current_optimal_mode_ENT_index}; 
            end
        end
    end
    %gotta determine uh. Assumes human is executes the "straightest
    %possible motion in the current mode towards the specified goal". 
    uh = generate_full_uh(random_goal, xr);
    zero_dim = setdiff(1:nd,current_optimal_mode_ENT);
    for jj=1:length(zero_dim)
        uh(zero_dim(jj)) = 0;
    end
%     uh = 0.2*(uh./(abs(uh) + realmin));
    if norm(uh) > 0.2
        uh = 0.2*(uh./(norm(uh) + realmin));
    end
    if rand < amp_sparsity_factor
        uh = rand*uh;
    end
    ur = generate_autonomy(curr_goal_index_ENT); %autonomy command in full 2D space
    alpha_ENT(i) = alpha_from_confidence(pgs_ENT(curr_goal_index_ENT, i)); %linear belnding param
    blend_vel = (1-alpha_ENT(i))*uh + alpha_ENT(i)*ur; %blended vel
    uh_ENT(:, i) = uh; ur_ENT(:, i) = ur; blend_vel_ENT(:, i) = blend_vel;

    if strcmp(intent_type, 'dft')
        pgs_ENT(:, i+1) = compute_p_of_g_dft_R2(uh, xr, pgs_ENT(:, i));
    elseif strcmp(intent_type, 'bayes')
        pgs_ENT(:, i+1) = compute_bayes_R2(uh, xr, pgs_ENT(:, i));
%         pgs_ENT(:, i+1) = compute_bayes_n_R2(uh_ENT(:, max(1, i-hist_length+1):i), xr, pgs_ENT(:,i));
    elseif strcmp(intent_type, 'conf')
        pgs_ENT(:, i+1) = compute_conf_R2(uh, xr);
    end
    
    xr = sim_kinematics_R2(xr, blend_vel); %forward simulate kinematics with blending. 
    traj_ENT(:, i+1) = xr;
    optimal_modes_ENT(i) = current_optimal_mode_ENT;
end

%% USING KL DIVERGENCE
fprintf("SIMULATION USING KL DIVERGENCE INFORMATION \n");

xr = xr_true; %reset the robot position to starting position
pgs_KL = zeros(ng, total_time_steps);
optimal_modes_KL = zeros(total_time_steps-1, 1);
alpha_KL = zeros(total_time_steps-1, 1);
uh_KL = zeros(nd, total_time_steps-1);
ur_KL = zeros(nd, total_time_steps-1);
blend_vel_KL = zeros(nd, total_time_steps-1);
curr_goal_KL = zeros(total_time_steps-1, 1);
traj_KL = zeros(nd, total_time_steps);
traj_KL(:, 1) = xr;
pgs_KL(:, 1) = (1/ng)*ones(ng, 1);%uniform probability to start off with. This is the true pg distribution during the course of the trajectory
%internally projection
current_optimal_mode_KL_index = init_mode_index;
current_optimal_mode_KL = cm{current_optimal_mode_KL_index};

for i=1:total_time_steps-1
    if norm(traj_KL(:, i) - random_goal)/norm(traj_KL(:, 1)- random_goal) < exit_threshold
        fprintf('Within 10 percent of the original separation from goal. Stopping simulation\n');
        break;
    end
    %compute the optimal mode. store it away. 
    curr_goal_index_KL = datasample(find(pgs_KL(:, i) == max(pgs_KL(:, i))), 1);
    curr_goal_KL(i) = curr_goal_index_KL;
    if mod(i-1, mode_comp_timesteps) == 0
        current_optimal_mode_KL_index = compute_optimal_mode_KL_R2_human_model(intent_type, xr, pgs_KL(:, i)); 
        if length(current_optimal_mode_KL_index) > 1 %when there are equivalent modes. 
            current_optimal_mode_KL = cm{current_optimal_mode_KL_index(1)}; %pick the first one. 
            current_optimal_mode_KL_index = current_optimal_mode_KL_index(1); %update the index. 
        else
            if current_optimal_mode_KL_index ~= -1 %if -1, don't change any mode. keep previous node. So no need to update
                current_optimal_mode_KL = cm{current_optimal_mode_KL_index}; 
            end
        end
    end
    %gotta determine uh. Assumes human is executes the "straightest
    %possible motion in the current mode towards the specified goal". 
    uh = generate_full_uh(random_goal, xr);
    zero_dim = setdiff(1:nd,current_optimal_mode_KL);
    for jj=1:length(zero_dim)
        uh(zero_dim(jj)) = 0;
    end
     if norm(uh) > 0.2
        uh = 0.2*(uh./(norm(uh) + realmin));
     end
    if rand < amp_sparsity_factor
        uh = rand*uh;
    end
    ur = generate_autonomy(curr_goal_index_KL); %autonomy command in full 2D space
    alpha_KL(i) = alpha_from_confidence(pgs_KL(curr_goal_index_KL, i)); %linear belnding param
    blend_vel = (1-alpha_KL(i))*uh + alpha_KL(i)*ur; %blended vel
    uh_KL(:, i) = uh; ur_KL(:, i) = ur; blend_vel_KL(:, i) = blend_vel;

    if strcmp(intent_type, 'dft')
        pgs_KL(:, i+1) = compute_p_of_g_dft_R2(uh, xr, pgs_KL(:, i));
    elseif strcmp(intent_type, 'bayes')
        pgs_KL(:, i+1) = compute_bayes_R2(uh, xr, pgs_KL(:, i));
%         pgs_KL(:, i+1) = compute_bayes_n_R2(uh_KL(:, max(1, i-hist_length+1):i), xr, pgs_KL(:,i));
    elseif strcmp(intent_type, 'conf')
        pgs_KL(:, i+1) = compute_conf_R2(uh, xr);
    end
    
    xr = sim_kinematics_R2(xr, blend_vel); %forward simulate kinematics with blending. 
    traj_KL(:, i+1) = xr;
    optimal_modes_KL(i) = current_optimal_mode_KL_index;
end


%% USING FI
% fprintf("SIMULATION USING FISHER INFORMATION \n");
% xr = xr_true;
% pgs_FI = zeros(ng, total_time_steps);
% optimal_modes_FI = zeros(total_time_steps-1, 1);
% alpha_FI = zeros(total_time_steps-1, 1);
% uh_FI = zeros(nd, total_time_steps-1);
% ur_FI = zeros(nd, total_time_steps-1);
% blend_vel_FI = zeros(nd, total_time_steps-1);
% curr_goal_FI = zeros(total_time_steps-1, 1);
% traj_FI = zeros(nd, total_time_steps);
% traj_FI(:, 1) = xr;
% pgs_FI(:, 1) = (1/ng)*ones(ng, 1);
% current_optimal_mode_FI = 1;
% for i=1:total_time_steps-1
%     %obtain current goal.
%     curr_goal_index_FI = datasample(find(pgs_FI(:, i) == max(pgs_FI(:, i))), 1);
%     curr_goal_FI(i) =  curr_goal_index_FI;
%     %compute the optimal mode. store it away. 
%     if mod(i-1, mode_comp_timesteps) == 0
%         current_optimal_mode_FI_index = compute_optimal_mode_FI_R2(intent_type, xr, pgs_FI(:, i)); 
%         if length(current_optimal_mode_FI_index) > 1 %when there are equivalent modes. 
%             current_optimal_mode_FI = cm{current_optimal_mode_FI_index(1)}; %pick the first one. 
%             current_optimal_mode_FI_index = current_optimal_mode_FI_index(1); %update the index. 
%         else
%             if current_optimal_mode_FI_index ~= -1 %if -1, don't change any mode. keep previous node. So no need to update
%                 current_optimal_mode_FI = cm{current_optimal_mode_FI_index}; 
%             end
%         end
%     end
%     %gotta determine uh. 
%     uh = generate_full_uh(random_goal, xr);
%     zero_dim = setdiff(1:nd,current_optimal_mode_FI);
%     for jj=1:length(zero_dim)
%         uh(zero_dim(jj)) = 0;
%     end
%     uh = 0.2*(uh/(norm(uh) + realmin));
%     ur = generate_autonomy(curr_goal_index_FI); %autonomy command in full 2D space
%     alpha_FI(i) = alpha_from_confidence(pgs_FI(curr_goal_index_FI, i)); %linear belnding param
%     blend_vel = (1-alpha_FI(i))*uh + alpha_FI(i)*ur; %blended vel
%     uh_FI(:, i) = uh; ur_FI(:, i) = ur; blend_vel_FI(:, i) = blend_vel;
%     if strcmp(intent_type, 'dft')
%         pgs_FI(:, i+1) = compute_p_of_g_dft_R2(uh, xr, pgs_FI(:, i));
%     elseif strcmp(intent_type, 'bayes')
%         pgs_FI(:, i+1) = compute_bayes_R2(uh, xr, pgs_FI(:, i));
% %         pgs_FI(:, i+1) = compute_bayes_n_R2(uh_FI(:, max(1, i-hist_length+1):i), xr, pgs_FI(:,i));
%     elseif strcmp(intent_type, 'conf')
%         pgs_FI(:, i+1) = compute_conf_R2(uh, xr);
%     end
%     xr = sim_kinematics_R2(xr, blend_vel); %forward simulate kinematics with blending. 
%     traj_FI(:, i+1) = xr;
%     optimal_modes_FI(i) = current_optimal_mode_FI;
% end
%% DISAMB METRIC BASED
fprintf("SIMULATION USING DISAMB METRIC \n");
xr = xr_true;
pgs_DISAMB = zeros(ng, total_time_steps);
optimal_modes_DISAMB = zeros(total_time_steps-1, 1);
alpha_DISAMB = zeros(total_time_steps-1, 1);
uh_DISAMB = zeros(nd, total_time_steps-1);
ur_DISAMB = zeros(nd, total_time_steps-1);
blend_vel_DISAMB = zeros(nd, total_time_steps-1);
curr_goal_DISAMB = zeros(total_time_steps-1, 1);
traj_DISAMB = zeros(nd, total_time_steps);
traj_DISAMB(:, 1) = xr; %(x,y,theta)
pgs_DISAMB(:, 1) = (1/ng)*ones(ng, 1);%uniform probability to start off with. This is the true pg distribution during the course of the trajectory
%internally projection

current_optimal_mode_DISAMB_index = init_mode_index;
current_optimal_mode_DISAMB = cm{current_optimal_mode_DISAMB_index};

for i=1:total_time_steps-1
    if norm(traj_DISAMB(:, i) - random_goal)/norm(traj_DISAMB(:, 1)- random_goal) < exit_threshold
        fprintf('Within 10 percent of the original separation from goal. Stopping simulation\n');
        break;
    end
    curr_goal_index_DISAMB = datasample(find(pgs_DISAMB(:, i) == max(pgs_DISAMB(:, i))), 1);
    curr_goal_DISAMB(i) = curr_goal_index_DISAMB;
    if mod(i-1, mode_comp_timesteps) == 0
        current_optimal_mode_DISAMB_index = compute_optimal_mode_DISAMB_R2(intent_type, xr, pgs_DISAMB(:, i)); 
        if length(current_optimal_mode_DISAMB_index) > 1 %when there are equivalent modes. 
            current_optimal_mode_DISAMB = cm{current_optimal_mode_DISAMB_index(1)}; %pick the first one. 
            current_optimal_mode_DISAMB_index = current_optimal_mode_DISAMB_index(1); %update the index. 
        else
            if current_optimal_mode_DISAMB_index ~= -1 %if -1, don't change any mode. keep previous node. So no need to update
                current_optimal_mode_DISAMB = cm{current_optimal_mode_DISAMB_index}; 
            end
        end
    end
    uh = generate_full_uh(random_goal, xr);
    zero_dim = setdiff(1:nd,current_optimal_mode_DISAMB);
    for jj=1:length(zero_dim)
        uh(zero_dim(jj)) = 0;
    end
     if norm(uh) > 0.2
        uh = 0.2*(uh./(norm(uh) + realmin));
    end
    ur = generate_autonomy(curr_goal_index_DISAMB);
    alpha_DISAMB(i) = alpha_from_confidence(pgs_DISAMB(curr_goal_index_DISAMB, i)); %linear belnding param
    blend_vel = (1-alpha_DISAMB(i))*uh + alpha_DISAMB(i)*ur; %blended vel
    uh_DISAMB(:, i) = uh; ur_DISAMB(:, i) = ur; blend_vel_DISAMB(:, i) = blend_vel;
    if strcmp(intent_type, 'dft')
        pgs_DISAMB(:, i+1) = compute_p_of_g_dft_R2(uh, xr, pgs_DISAMB(:, i));
    elseif strcmp(intent_type, 'bayes')
        pgs_DISAMB(:, i+1) = compute_bayes_R2(uh, xr, pgs_DISAMB(:, i));
%         pgs_DISAMB(:, i+1) = compute_bayes_n_R2(uh_DISAMB(:, max(1, i-hist_length+1):i), xr, pgs_DISAMB(:,i));
    elseif strcmp(intent_type, 'conf')
        pgs_DISAMB(:, i+1) = compute_conf_R2(uh, xr);
    end
    xr = sim_kinematics_R3(xr, blend_vel);
    traj_DISAMB(:, i+1) = xr;
    optimal_modes_DISAMB(i) = current_optimal_mode_DISAMB_index; 
end

%% PLOT TRAJECTORIES
% hold on; 
% scatter(traj_POT(1, :)', traj_POT(2, :)', 'k', 'filled');
% scatter(traj_ENT(1, :)', traj_ENT(2, :)', 'r', 'filled');
% scatter(traj_KL(1, :)', traj_KL(2, :)', 'b', 'filled');
% scatter(traj_FI(1, :)', traj_FI(2, :)', 'b', 'filled');
% scatter(traj_DISAMB(1, :)', traj_DISAMB(2, :)', 'g', 'filled');

%% PLOT PROBABILITIES AND THE DISAMB MODES. 
% plot_script;
% plot_goal_match;

%% generate u_h
function uh = generate_full_uh(xg, xr) %full unnomralized uh
    global nd sparsity_factor kappa;
    mu = xg - xr;
    uh = randvonMisesFisherm(nd, 1, kappa, mu);
    %add sparsity
    if rand < sparsity_factor
        uh = zeros(nd, 1);
    end
    
end

%% simple potential field type of autonomy. 
function ur = generate_autonomy(goal_index)
    global xr xg;
    ur = xg(:, goal_index) - xr;
    if norm(ur) > 0.20
        ur = 0.2*ur/norm(ur);
    end
end
%% arbitration function

function alpha = alpha_from_confidence(goal_pg)
   global conf_thresh conf_max alpha_max
   if goal_pg <= conf_thresh
       alpha = 0.0;
   elseif goal_pg > conf_thresh && goal_pg <= conf_max
       alpha = (goal_pg - conf_thresh)*(alpha_max/(conf_max - conf_thresh));
   else
       alpha = alpha_max;
   end
end

%%
function [ best_mode ] = compute_optimal_mode_POT_R2(xg, xr_true)
    global cm nd xr;
    Pk = zeros(nd, 1);
    Pcm = zeros(length(cm), 1); % Fractional Potnetial for each mode. 
    for i=1:nd
        Pk(i) = abs((xg(i) - xr(i))/(xg(i) - xr_true(i))); %Fractional potential. 
    end
    for i=1:length(cm)
        Pcm(i) = sum(Pk(cm{i}));
    end
    best_mode = compute_best_mode(Pcm);
end